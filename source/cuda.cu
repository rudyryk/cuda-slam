#include "cuda.cuh"
#include "functors.cuh"
#include "svdparams.cuh"
#include "parallelsvdhelper.cuh"

namespace {
	typedef thrust::device_vector<glm::vec3> Cloud;
	typedef thrust::device_vector<int> IndexIterator;
	typedef thrust::permutation_iterator<Cloud, IndexIterator> Permutation;

	thrust::host_vector<glm::vec3> CommonToThrustVector(const std::vector<Common::Point_f>& vec)
	{
		thrust::host_vector<glm::vec3> hostCloud(vec.size());
		for (int i = 0; i < vec.size(); i++)
			hostCloud[i] = (glm::vec3)vec[i];

		return hostCloud;
	}

	std::vector<Point_f> ThrustToCommonVector(const Cloud& vec)
	{
		thrust::host_vector<glm::vec3> hostCloud = vec;
		std::vector<Point_f> outVector(vec.size());
		for (int i = 0; i < hostCloud.size(); i++)
			outVector[i] = { hostCloud[i].x, hostCloud[i].y, hostCloud[i].z };

		return outVector;
	}

	glm::vec3 CalculateCentroid(const Cloud& vec)
	{
		const auto sum = thrust::reduce(thrust::device, vec.begin(), vec.end());
		return sum / static_cast<float>(vec.size());
	}

	void TransformCloud(const Cloud& vec, Cloud& out, const glm::mat4& transform)
	{
		const auto functor = Functors::MatrixTransform(transform);
		thrust::transform(thrust::device, vec.begin(), vec.end(), out.begin(), functor);
	}
	
	__device__ float GetDistanceSquared(const glm::vec3& first, const glm::vec3& second)
	{
		const auto d = second - first;
		return d.x * d.x + d.y * d.y + d.z * d.z;
	}

	__global__ void FindCorrespondences(int* result, const glm::vec3* before, const glm::vec3* after, int beforeSize, int afterSize)
	{
		int targetIdx = blockDim.x * blockIdx.x + threadIdx.x;
		if (targetIdx < beforeSize)
		{
			const glm::vec3 vector = before[targetIdx];
			int nearestIdx = 0;
			float smallestError = GetDistanceSquared(vector, after[0]);
			for (int i = 1; i < afterSize; i++)
			{
				const auto dist = GetDistanceSquared(vector, after[i]);
				if (dist < smallestError)
				{
					smallestError = dist;
					nearestIdx = i;
				}
			}
			
			result[targetIdx] = nearestIdx;
		}
	}

	void GetCorrespondingPoints(thrust::device_vector<int>& indices, const Cloud& before, const Cloud& after)
	{
#ifdef USE_CORRESPONDENCES_KERNEL
		int* dIndices = thrust::raw_pointer_cast(indices.data());
		const glm::vec3* dBefore = thrust::raw_pointer_cast(before.data());
		const glm::vec3* dAfter = thrust::raw_pointer_cast(after.data());
		int beforeSize = before.size();
		int afterSize = after.size();

		constexpr int threadsPerBlock = 256;
		const int blocksPerGrid = (beforeSize + threadsPerBlock - 1) / threadsPerBlock;
		FindCorrespondences << <blocksPerGrid, threadsPerBlock >> > (dIndices, dBefore, dAfter, beforeSize, afterSize);
		cudaDeviceSynchronize();
#else
		const auto nearestFunctor = Functors::FindNearestIndex(after);
		thrust::transform(thrust::device, before.begin(), before.end(), indices.begin(), nearestFunctor);
#endif
	}

	float GetMeanSquaredError(const IndexIterator& permutation, const Cloud& before, const Cloud& after)
	{
		auto permutationIteratorBegin = thrust::make_permutation_iterator(after.begin(), permutation.begin());
		auto permutationIteratorEnd = thrust::make_permutation_iterator(after.end(), permutation.end());
		auto zipBegin = thrust::make_zip_iterator(thrust::make_tuple(permutationIteratorBegin, before.begin()));
		auto zipEnd = thrust::make_zip_iterator(thrust::make_tuple(permutationIteratorEnd, before.end()));
		auto mseFunctor = Functors::MSETransform();
		auto sumFunctor = thrust::plus<float>();
		auto result = thrust::transform_reduce(thrust::device, zipBegin, zipEnd, mseFunctor, 0.f, sumFunctor);
		return result / after.size();
	}

	void GetAlignedCloud(const Cloud& source, Cloud& target)
	{
		const auto centroid = CalculateCentroid(source);
		const auto transform = Functors::TranslateTransform(-centroid);
		thrust::transform(thrust::device, source.begin(), source.end(), target.begin(), transform);
	}

	void CuBlasMultiply(float* A, float* B, float* C, int size, CudaSvdParams& params)
	{
		const float alpha = 1.f, beta = 0.f;
		cublasSgemm(params.multiplyHandle, CUBLAS_OP_N, CUBLAS_OP_N, 3, 3, size, &alpha, A, 3, B, size, &beta, C, 3);
	}

	glm::mat4 LeastSquaresSVD(const IndexIterator& permutation, const Cloud& before, const Cloud& after, Cloud& alignBefore, Cloud& alignAfter, CudaSvdParams params)
	{
		const int size = before.size();

		//align arrays
		const auto centroidBefore = CalculateCentroid(before);
		GetAlignedCloud(before, alignBefore);
		
		auto permutationIteratorBegin = thrust::make_permutation_iterator(after.begin(), permutation.begin());
		auto permutationIteratorEnd = thrust::make_permutation_iterator(after.end(), permutation.end());
		thrust::copy(thrust::device, permutationIteratorBegin, permutationIteratorEnd, alignAfter.begin());
		const auto centroidAfter = CalculateCentroid(alignAfter);
		GetAlignedCloud(alignAfter, alignAfter);

		//create array AFTER (transposed)
		auto countingBegin = thrust::make_counting_iterator<int>(0);
		auto countingEnd = thrust::make_counting_iterator<int>(alignAfter.size());
		auto zipBegin = thrust::make_zip_iterator(thrust::make_tuple(countingBegin, alignAfter.begin()));
		auto zipEnd = thrust::make_zip_iterator(thrust::make_tuple(countingEnd, alignAfter.end()));

		auto convertAfter = Functors::GlmToCuBlas(true, size, params.workAfter);
		thrust::for_each(thrust::device, zipBegin, zipEnd, convertAfter);

		//create array BEFORE
		const auto beforeZipBegin = thrust::make_zip_iterator(thrust::make_tuple(countingBegin, alignBefore.begin()));
		const auto beforeZipEnd = thrust::make_zip_iterator(thrust::make_tuple(countingEnd, alignBefore.end()));
		auto convertBefore = Functors::GlmToCuBlas(false, before.size(), params.workBefore);
		thrust::for_each(thrust::device, beforeZipBegin, beforeZipEnd, convertBefore);

		//multiply
		CuBlasMultiply(params.workBefore, params.workAfter, params.multiplyResult, size, params);
		float result[9];
		cudaMemcpy(result, params.multiplyResult, 9 * sizeof(float), cudaMemcpyDeviceToHost);
		auto matrix = CreateGlmMatrix(result);
		//return Common::GetTransform(matrix, centroidBefore, centroidAfter);

		float transposed[9];
		for (int i = 0; i < 3; i++)
			for (int j = 0; j < 3; j++)
				transposed[3 * i + j] = result[3 * j + i];
		cudaMemcpy(params.multiplyResult, transposed, 9 * sizeof(float), cudaMemcpyHostToDevice);

		//svd
		cusolverDnSgesvd(params.solverHandle, 'A', 'A', params.m, params.n, params.multiplyResult, params.m, params.S, params.U, params.m, params.VT, params.n, params.work, params.workSize, nullptr, params.devInfo);
		int svdResultInfo = 0;
		cudaMemcpy(&svdResultInfo, params.devInfo, sizeof(int), cudaMemcpyDeviceToHost);
		if (svdResultInfo != 0)
			printf("Svd execution failed!\n");

		float hostS[9], hostVT[9], hostU[9];
		const int copySize = 9 * sizeof(float);
		cudaMemcpy(hostS, params.S, copySize, cudaMemcpyDeviceToHost);
		cudaMemcpy(hostVT, params.VT, copySize, cudaMemcpyDeviceToHost);
		cudaMemcpy(hostU, params.U, copySize, cudaMemcpyDeviceToHost);

		auto gVT = glm::transpose(CreateGlmMatrix(hostVT));
		auto gU = glm::transpose(CreateGlmMatrix(hostU));

		//revert signs to match svd cpu solution
		for (int i = 0; i < 3; i++)
		{
			gU[1][i] = -gU[1][i];
			gVT[i][1] = -gVT[i][1];
		}

		const float determinant = glm::determinant(gU * gVT);
		const auto diagonal = glm::diagonal3x3(glm::vec3 { 1.f, 1.f, determinant });
		const auto rotation = gU * diagonal * gVT;

		const auto translation = centroidAfter - rotation * centroidBefore;

		auto transformation = glm::mat4(0.f);
		for (int i = 0; i < 3; i++)
			for (int j = 0; j < 3; j++)
				transformation[i][j] = rotation[i][j];

		transformation[3][0] = translation.x;
		transformation[3][1] = translation.y;
		transformation[3][2] = translation.z;
		transformation[3][3] = 1.0f;

		return transformation;
	}

	glm::mat3 GetSVDMatrixU(const Cloud& cloud, Cloud& alignCloud, glm::vec3& centroid)
	{
		// Allocate memory for cuBLAS
		CudaSvdParams params(cloud.size(), cloud.size(), cloud.size(), 3, false);

		// Align array
		centroid = CalculateCentroid(cloud);
		GetAlignedCloud(cloud, alignCloud);

		// Create counting iterators
		auto countingBegin = thrust::make_counting_iterator<int>(0);
		auto countingEnd = thrust::make_counting_iterator<int>(alignCloud.size());

		// Create array for SVD
		const auto beforeZipBegin = thrust::make_zip_iterator(thrust::make_tuple(countingBegin, alignCloud.begin()));
		const auto beforeZipEnd = thrust::make_zip_iterator(thrust::make_tuple(countingEnd, alignCloud.end()));
		auto convertBefore = Functors::GlmToCuBlas(true, cloud.size(), params.workBefore);
		thrust::for_each(thrust::device, beforeZipBegin, beforeZipEnd, convertBefore);

		// Apply SVD for array
		cusolverDnSgesvd(params.solverHandle, 'N', 'A', params.m, params.n, params.workBefore, params.m, params.S, params.U, params.m, params.VT, params.n, params.work, params.workSize, nullptr, params.devInfo);
		int svdResultInfo = 0;
		cudaMemcpy(&svdResultInfo, params.devInfo, sizeof(int), cudaMemcpyDeviceToHost);
		if (svdResultInfo != 0)
			printf("Svd execution failed!\n");

		// Convert SVD result to glm
		float result[9];
		// Use V^T matrix instead of U as we pass transposed matrix to cusolver
		// A = U * S * V => A^T = V^T * S^T * U^T => U(A^T)  = V^T (more or less :) )
		cudaMemcpy(result, params.VT, 9 * sizeof(float), cudaMemcpyDeviceToHost);

		params.Free();
		return CreateGlmMatrix(result);
	}

	Cloud ApplyPermutation(const Cloud& inputCloud, IndexIterator permutation)
	{
		Cloud outputCloud(inputCloud.size());

		int permutationSize = permutation.size();
		if (permutationSize < inputCloud.size())
		{
			permutation.resize(inputCloud.size());
			auto helperCountingIterator = thrust::make_counting_iterator(0);
			thrust::copy(helperCountingIterator + permutationSize, helperCountingIterator + inputCloud.size(), permutation.begin() + permutationSize);
		}

		const auto applyPermutationFunctor = Functors::Permutation(inputCloud);
		thrust::transform(thrust::device, permutation.begin(), permutation.end(), outputCloud.begin(), applyPermutationFunctor);

		return outputCloud;
	}

	void PrepareMatricesForParallelSVD(const Cloud& cloudBefore, const Cloud& cloudAfter, int batchSize, thrust::host_vector<float*> &outputBefore, thrust::host_vector<float*> &outputAfter)
	{
		int cloudSize = std::min(cloudBefore.size(), cloudAfter.size());

		outputBefore.resize(batchSize);
		outputAfter.resize(batchSize);
		for (int i = 0; i < batchSize; i++)
		{
			cudaMalloc(&(outputBefore[i]), 3 * cloudBefore.size() * sizeof(float));
			cudaMalloc(&(outputAfter[i]), 3 * cloudAfter.size() * sizeof(float));
		}

		Cloud alignBefore(cloudBefore.size());
		Cloud alignAfter(cloudAfter.size());

		// Align array
		GetAlignedCloud(cloudBefore, alignBefore);
		GetAlignedCloud(cloudAfter, alignAfter);


		thrust::host_vector<glm::vec3> debug(alignAfter.size());
		thrust::copy(alignAfter.begin(), alignAfter.end(), debug.begin());
		FILE* file;
		file = fopen("glm-debug.txt", "w+");

		for (int j = 0; j < debug.size(); j++)
			fprintf(file, "[j=%d] %f, %f, %f\n", j, debug[j].x, debug[j].y, debug[j].z);
		fclose(file);

		for (int i = 0; i < batchSize; i++)
		{
			// Generate permutation
			std::vector<int> h_permutation = GetRandomPermutationVector(cloudSize);
			IndexIterator d_permutation(h_permutation.size());


			// FAKE PERMUTATION
			thrust::counting_iterator<int> helper(0);
			thrust::copy(helper, helper + h_permutation.size(), h_permutation.begin());
			// END OF FAKE PERMUTATION


			thrust::copy(h_permutation.begin(), h_permutation.end(), d_permutation.begin());
			auto permutedBefore = ApplyPermutation(alignBefore, d_permutation);
			auto permutedAfter = ApplyPermutation(alignAfter, d_permutation);

			// Create counting iterators
			auto beforeCountingBegin = thrust::make_counting_iterator<int>(0);
			auto beforeCountingEnd = thrust::make_counting_iterator<int>(permutedBefore.size());
			auto afterCountingBegin = thrust::make_counting_iterator<int>(0);
			auto afterCountingEnd = thrust::make_counting_iterator<int>(permutedAfter.size());

			// Create array for SVD
			const auto beforeZipBegin = thrust::make_zip_iterator(thrust::make_tuple(beforeCountingBegin, permutedBefore.begin()));
			const auto beforeZipEnd = thrust::make_zip_iterator(thrust::make_tuple(beforeCountingEnd, permutedBefore.end()));
			auto convertBefore = Functors::GlmToCuBlas(false, permutedBefore.size(), outputBefore[i]);
			thrust::for_each(thrust::device, beforeZipBegin, beforeZipEnd, convertBefore);
			const auto afterZipBegin = thrust::make_zip_iterator(thrust::make_tuple(afterCountingBegin, permutedAfter.begin()));
			const auto afterZipEnd = thrust::make_zip_iterator(thrust::make_tuple(afterCountingEnd, permutedAfter.end()));
			auto convertAfter = Functors::GlmToCuBlas(false, permutedAfter.size(), outputAfter[i]);
			thrust::for_each(thrust::device, afterZipBegin, afterZipEnd, convertAfter);


			if (i == 0)
			{
				float* debug2 = (float*)malloc(3 * cloudAfter.size() * sizeof(float));
				cudaMemcpy(debug2, outputAfter[i], 3 * cloudAfter.size() * sizeof(float), cudaMemcpyDeviceToHost);
				FILE* file2;
				file2 = fopen("cublas-debug.txt", "w+");

				for (int j = 0; j < 3 * cloudAfter.size(); j += 3)
					fprintf(file2, "[j=%d] %f, %f, %f\n", j / 3, debug2[j], debug2[j + 1], debug2[j + 2]);
				free(debug2);
				fclose(file2);
			}
		}
	}

	void GetSVDMatricesUParallel(const Cloud& cloudBefore, const Cloud &cloudAfter, int batchSize, thrust::host_vector<glm::mat3> &outputBefore, thrust::host_vector<glm::mat3> &outputAfter)
	{
		thrust::host_vector<float*> preparedBefore;
		thrust::host_vector<float*> preparedAfter;

		PrepareMatricesForParallelSVD(cloudBefore, cloudAfter, batchSize, preparedBefore, preparedAfter);

		// Run SVD for cloud before
		CudaParallelSvdHelper svdBefore(batchSize, cloudBefore.size(), 3, false);
		svdBefore.RunSVD(preparedBefore);
		outputBefore = svdBefore.GetHostMatricesVT();
		svdBefore.FreeMemory();

		// Run SVD for cloud after
		float* debug = (float*)malloc(3 * cloudAfter.size() * sizeof(float));
		cudaMemcpy(debug, preparedAfter[0], 3 * cloudAfter.size() * sizeof(float), cudaMemcpyDeviceToHost);
		cudaDeviceSynchronize();

		for (int i = 0; i < 3 * cloudAfter.size(); i+=3)
			printf("[i=%d] %f, %f, %f\n", i / 3, debug[i], debug[i + 1], debug[i + 2]);



		CudaParallelSvdHelper svdAfter(batchSize, cloudAfter.size(), 3, false);
		svdAfter.RunSVD(preparedAfter);
		outputAfter = svdAfter.GetHostMatricesVT();
		svdAfter.FreeMemory();

		for (int i = 0; i < batchSize; i++)
		{
			if(preparedBefore[i])
				cudaFree(preparedBefore[i]);

			if (preparedAfter[i])
				cudaFree(preparedAfter[i]);
		}
	}

	glm::mat4 CudaICP(const Cloud& before, const Cloud& after)
	{
		const int maxIterations = 60;
		const float TEST_EPS = 1e-5;
		float previousError = std::numeric_limits<float>::max();

		int iterations = 0;
		glm::mat4 transformationMatrix(1.0f);
		glm::mat4 previousTransformationMatrix = transformationMatrix;

		//do not change before vector - copy it for calculations
		const int size = std::max(before.size(), after.size());
		Cloud workingBefore(size);
		Cloud alignBefore(size);
		Cloud alignAfter(size);
		thrust::device_vector<int> indices(before.size());
		thrust::copy(thrust::device, before.begin(), before.end(), workingBefore.begin());

		//allocate memory for cuBLAS
		CudaSvdParams params(size, size, 3, 3);
		
		while (iterations < maxIterations)
		{
			GetCorrespondingPoints(indices, workingBefore, after);

			transformationMatrix = LeastSquaresSVD(indices, workingBefore, after, alignBefore, alignAfter, params) * transformationMatrix;

			TransformCloud(before, workingBefore, transformationMatrix);
			float error = GetMeanSquaredError(indices, workingBefore, after);
			printf("Iteration: %d, error: %f\n", iterations, error);
			if (error < TEST_EPS)
				break;

			if (error > previousError)
			{
				printf("Error has increased, aborting\n");
				transformationMatrix = previousTransformationMatrix;
				break;
			}

			previousTransformationMatrix = transformationMatrix;
			previousError = error;
			iterations++;
		}
		
		params.Free();
		return transformationMatrix;
	}

	void CudaSingleNonIterativeSlam(const Cloud& before, const Cloud& after, const Cloud& subcloud, float &error, glm::mat4 &transformationMatrix)
	{
		const int maxIterations = 60;
		const float TEST_EPS = 1e-5;
		float previousError = std::numeric_limits<float>::max();

		int iterations = 0;
		transformationMatrix = glm::mat4(1.0f);

		Cloud alignBefore(before.size());
		Cloud alignAfter(after.size());
		thrust::device_vector<int> indices(before.size());
		glm::vec3 centroidBefore, centroidAfter;

		auto uMatrixBefore = GetSVDMatrixU(before, alignBefore, centroidBefore);
		auto uMatrixAfter = GetSVDMatrixU(after, alignAfter, centroidAfter);

		auto rotationMatrix = uMatrixAfter * glm::transpose(uMatrixBefore);
		auto translationVector = glm::vec3(centroidAfter) - (rotationMatrix * centroidBefore);

		for (int i = 0; i < 3; i++)
			for (int j = 0; j < 3; j++)
				transformationMatrix[i][j] = rotationMatrix[i][j];

		transformationMatrix[3][0] = translationVector.x;
		transformationMatrix[3][1] = translationVector.y;
		transformationMatrix[3][2] = translationVector.z;
		transformationMatrix[3][3] = 1.0f;

		Cloud workingSubcloud(subcloud.size());
		TransformCloud(subcloud, workingSubcloud, transformationMatrix);
		GetCorrespondingPoints(indices, workingSubcloud, after);
		error = GetMeanSquaredError(indices, workingSubcloud, after);
	}

	Cloud GetSubcloud(const Cloud& cloud, int subcloudSize)
	{
		if (subcloudSize >= cloud.size())
			return cloud;
		std::vector<int> subcloudIndices = GetRandomPermutationVector(cloud.size());
		subcloudIndices.resize(subcloudSize);
		thrust::device_vector<int> indices(subcloudIndices);

		Cloud subcloud(subcloudIndices.size());
		const auto getSubcloudFunctor = Functors::Permutation(cloud);
		thrust::transform(thrust::device, indices.begin(), indices.end(), subcloud.begin(), getSubcloudFunctor);

		return subcloud;
	}

	glm::mat4 CudaNonIterativeParallel(const Cloud& before, const Cloud& after, int* repetitions, float* error, float eps, int maxRepetitions, int cpuThreadsCount, const int subcloudSize)
	{
		maxRepetitions = 1;

		thrust::host_vector<glm::mat3> matricesBefore(maxRepetitions);
		thrust::host_vector<glm::mat3> matricesAfter(maxRepetitions);

		GetSVDMatricesUParallel(before, after, maxRepetitions, matricesBefore, matricesAfter);

		// Hardcoded centers of bunny.obj clouds for test purposes
		auto centroidBefore = glm::vec3(-28.1278152, 94.5905228, 9.00993729);
		auto centroidAfter = glm::vec3(-32.1814156, 92.5075684, 15.2964954);
		//auto centroidBefore = CalculateCentroid(before);
		//auto centroidAfter = CalculateCentroid(after);

		for (int i = 0; i < maxRepetitions; i++)
		{
			auto transformationMatrix = glm::mat4(1.0f);

			auto rotationMatrix = matricesAfter[i] * glm::transpose(matricesBefore[i]);
			auto translationVector = centroidAfter - (rotationMatrix * centroidBefore);

			for (int i = 0; i < 3; i++)
				for (int j = 0; j < 3; j++)
					transformationMatrix[i][j] = rotationMatrix[i][j];

			transformationMatrix[3][0] = translationVector.x;
			transformationMatrix[3][1] = translationVector.y;
			transformationMatrix[3][2] = translationVector.z;
			transformationMatrix[3][3] = 1.0f;

			for (int i = 0; i < 4; i++)
			{
				for (int j = 0; j < 4; j++)
				{
					printf("%f\t", transformationMatrix[i][j]);
				}
				printf("\n");
			}
			printf("\n");

			//Cloud workingSubcloud(subcloud.size());
			//TransformCloud(subcloud, workingSubcloud, transformationMatrix);
			//GetCorrespondingPoints(indices, workingSubcloud, after);
			//error = GetMeanSquaredError(indices, workingSubcloud, after);

			if (i == maxRepetitions - 1)
				return transformationMatrix;
		}
	}

	glm::mat4 CudaNonIterativeV2(const Cloud& before, const Cloud& after, int* repetitions, float* error, float eps, int maxRepetitions, int cpuThreadsCount, const int subcloudSize)
	{
		//cpuThreadsCount = 2;

		glm::mat4 transformResult(1.0f);
		*error = std::numeric_limits<float>::max();

		// Get subcloud
		const Cloud subcloud = GetSubcloud(before, subcloudSize);

		int batchesCount = maxRepetitions / cpuThreadsCount;
		int lastBatchSize = maxRepetitions % cpuThreadsCount;
		int threadsToRun = cpuThreadsCount;
		std::vector<std::thread> workerThreads(cpuThreadsCount);
		std::vector<float> errors(cpuThreadsCount);
		std::vector<glm::mat4> resultMatrix(cpuThreadsCount);

		// Create copy for each thread
		std::vector<Cloud> workingBefore(cpuThreadsCount);
		std::vector<Cloud> workingAfter(cpuThreadsCount);
		std::vector<Cloud> workingSubcloud(cpuThreadsCount);
		for (int i = 0; i < cpuThreadsCount; i++)
		{
			workingBefore[i] = Cloud(before.size());
			workingAfter[i] = Cloud(after.size());
			workingSubcloud[i] = Cloud(subcloud.size());

			thrust::copy(thrust::device, before.begin(), before.end(), workingBefore[i].begin());
			thrust::copy(thrust::device, after.begin(), after.end(), workingAfter[i].begin());
			thrust::copy(thrust::device, subcloud.begin(), subcloud.end(), workingSubcloud[i].begin());
		}

		const auto thread_work = [&](int index) {
			CudaSingleNonIterativeSlam(workingBefore[index], workingAfter[index], workingSubcloud[index], errors[index], resultMatrix[index]);
		};

		for (int i = 0; i <= batchesCount; i++)
		{
			if (i == batchesCount)
			{
				if (lastBatchSize != 0)
					threadsToRun = lastBatchSize;
				else
					break;
			}

			// Run CPU threads
			for (int j = 0; j < threadsToRun; j++)
				workerThreads[j] = std::thread(thread_work, j);

			// Wait for threads to finish
			for (int j = 0; j < threadsToRun; j++)
				workerThreads[j].join();

			// Process the results
			*repetitions += threadsToRun;
			for (int j = 0; j < threadsToRun; j++)
			{
				if (errors[j] <= eps)
				{
					*error = errors[j];
					return resultMatrix[j];
				}
				
				if (errors[j] < *error)
				{
					*error = errors[j];
					transformResult = resultMatrix[j];
				}
			}
		}

		return transformResult;
	}

	void CorrespondencesTest()
	{
		const int size = 100;
		thrust::device_vector<glm::vec3> input(size);
		thrust::device_vector<glm::vec3> output(size);
		thrust::device_vector<int> result(size);

		for (int i = 0; i < size; i++)
		{
			const auto vec = glm::vec3(i);
			input[i] = vec;
			output[size - i - 1] = vec;
		}


		GetCorrespondingPoints(result, input, output);
		thrust::host_vector<int> copy = result;
		bool ok = true;
		int hostArray[size];
		for (int i = 0; i < size; i++)
		{
			hostArray[i] = copy[i];
			if (copy[i] != size - i - 1)
				ok = false;
		}
		

		printf("Correspondence test [%s]\n", ok ? "OK" : "FAILED");
	}

	void MultiplicationTest()
	{
		const int size = 100;

		float ones[3 * size];
		for (int i = 0; i < 3 * size; i++)
			ones[i] = 1.f;


		CudaSvdParams params(size, size, 3, 3);
		cudaMemcpy(params.workBefore, ones, 3 * size * sizeof(float), cudaMemcpyHostToDevice);
		cudaMemcpy(params.workAfter, ones, 3 * size * sizeof(float), cudaMemcpyHostToDevice);

		CuBlasMultiply(params.workBefore, params.workAfter, params.multiplyResult, size, params);

		float result[9];
		cudaMemcpy(result, params.multiplyResult, 9 * sizeof(float), cudaMemcpyDeviceToHost);

		bool ok = true;
		for (int i = 0; i < 9; i++)
			if (abs(result[i] - size) > 1e-5)
				ok = false;

		printf("Multiplication test [%s]\n", ok ? "OK" : "FAILED");
		params.Free();
	}	
}

void NonIterativeCudaTest()
{
	/****************************/
	//TESTS
	/****************************/
	//MultiplicationTest();

	/****************************/
	//ALGORITHM
	/****************************/
	const auto testCloud = LoadCloud("data/bunny.obj");
	const auto testCorrupted = LoadCloud("data/bunny.obj");
	int repetitions;
	float error;
	const int maxRepetitions = 20;
	const int subcloudSize = 1000;
	const float eps = 1e-5;
	const int cpuThreadsCount = (int)std::thread::hardware_concurrency();
	//testCloud.resize(10000);
	//testCorrupted.resize(10000);

	const auto hostBefore = CommonToThrustVector(testCloud);
	const auto hostAfter = CommonToThrustVector(testCorrupted);

	Cloud deviceCloudBefore = hostBefore;
	Cloud deviceCloudAfter = hostAfter;

	Cloud calculatedCloud(hostAfter.size());

	const auto scaleInput = Functors::ScaleTransform(1000.f);
	thrust::transform(thrust::device, deviceCloudBefore.begin(), deviceCloudBefore.end(), deviceCloudBefore.begin(), scaleInput);
	const auto scaleInputCorrupted = Functors::ScaleTransform(1000.f);
	thrust::transform(thrust::device, deviceCloudAfter.begin(), deviceCloudAfter.end(), deviceCloudAfter.begin(), scaleInputCorrupted);

	const auto sampleTransform = glm::rotate(glm::translate(glm::mat4(1), { 0.05f, 0.05f, 0.05f }), glm::radians(5.f), { 0.5f, 0.5f, 0.5f });
	// TODO: Remove this debug print for sample transformation
	for (int i = 0; i < 4; i++)
	{
		for (int j = 0; j < 4; j++)
		{
			printf("%f\t", sampleTransform[i][j]);
		}
		printf("\n");
	}
	printf("\n");
	TransformCloud(deviceCloudAfter, deviceCloudAfter, sampleTransform);

	auto start = std::chrono::high_resolution_clock::now();
	const auto result = CudaNonIterativeParallel(deviceCloudBefore, deviceCloudAfter, &repetitions, &error, eps, maxRepetitions, cpuThreadsCount, subcloudSize);
	auto stop = std::chrono::high_resolution_clock::now();
	printf("Size: %d points, duration: %dms\n", testCloud.size(), std::chrono::duration_cast<std::chrono::milliseconds>(stop - start));

	TransformCloud(deviceCloudBefore, calculatedCloud, result);

	Common::Renderer renderer(
		Common::ShaderType::SimpleModel,
		ThrustToCommonVector(deviceCloudBefore), //grey
		ThrustToCommonVector(deviceCloudAfter), //blue
		ThrustToCommonVector(calculatedCloud), //red
		std::vector<Point_f>(1));

	renderer.Show();
}

glm::mat3 CreateGlmMatrix(float* squareMatrix)
{
	return glm::transpose(glm::make_mat3(squareMatrix));
}

void CudaTest()
{
	/****************************/
	//TESTS
	/****************************/
	CorrespondencesTest();
	MultiplicationTest();

	/****************************/
	//ALGORITHM
	/****************************/
	const auto testCloud = LoadCloud("data/bunny.obj");
	const auto testCorrupted = LoadCloud("data/bunny.obj");

	const auto hostBefore = CommonToThrustVector(testCloud);
	const auto hostAfter = CommonToThrustVector(testCorrupted);

	Cloud deviceCloudBefore = hostBefore;
	Cloud deviceCloudAfter = hostAfter;

	Cloud calculatedCloud(hostAfter.size());

	const auto scaleInput = Functors::ScaleTransform(1000.f);
	thrust::transform(thrust::device, deviceCloudBefore.begin(), deviceCloudBefore.end(), deviceCloudBefore.begin(), scaleInput);
	const auto scaleInputCorrupted = Functors::ScaleTransform(1000.f);
	thrust::transform(thrust::device, deviceCloudAfter.begin(), deviceCloudAfter.end(), deviceCloudAfter.begin(), scaleInputCorrupted);

	const auto sampleTransform = glm::rotate(glm::translate(glm::mat4(1), { 0.05f, 0.05f, 0.05f }), glm::radians(5.f), { 0.5f, 0.5f, 0.5f });
	TransformCloud(deviceCloudAfter, deviceCloudAfter, sampleTransform);

	auto start = std::chrono::high_resolution_clock::now();
	const auto result = CudaICP(deviceCloudBefore, deviceCloudAfter);
	auto stop = std::chrono::high_resolution_clock::now();
	printf("Size: %d points, duration: %dms\n", testCloud.size(), std::chrono::duration_cast<std::chrono::milliseconds>(stop - start));

	TransformCloud(deviceCloudBefore, calculatedCloud, result);

	Common::Renderer renderer(
			Common::ShaderType::SimpleModel,
			ThrustToCommonVector(deviceCloudBefore), //grey
			ThrustToCommonVector(deviceCloudAfter), //blue
			ThrustToCommonVector(calculatedCloud), //red
			std::vector<Point_f>(1));

	renderer.Show();
}
