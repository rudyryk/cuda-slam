#include "cuda.cuh"
#include "functors.cuh"

namespace {
	typedef thrust::device_vector<glm::vec3> Cloud;
	typedef thrust::device_vector<int> IndexIterator;
	typedef thrust::permutation_iterator<Cloud, IndexIterator> Permutation;

	thrust::host_vector<glm::vec3> CommonToThrustVector(const std::vector<Common::Point_f>& vec)
	{
		thrust::host_vector<glm::vec3> hostCloud(vec.size() * 3);
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
	
	IndexIterator GetCorrespondingPoints(const Cloud& before, const Cloud& after)
	{
		thrust::device_vector<int> indices(before.size());
		const auto nearestFunctor = Functors::FindNearestIndex(after);
		thrust::transform(thrust::device, before.begin(), before.end(), indices.begin(), nearestFunctor);
		return indices;
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

	void CuBlasMultiply(float* A, float* B, float* C, int size)
	{
		const float alpha = 1.f, beta = 0.f;
		cublasHandle_t handle;
		cublasCreate(&handle);
		cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, 3, 3, size, &alpha, A, 3, B, size, &beta, C, 3);
		cublasDestroy(handle);
	}

	glm::mat4 LeastSquaresSVD(const IndexIterator& permutation, const Cloud& before, const Cloud& after, Cloud& alignBefore, Cloud& alignAfter, float* workBefore, float* workAfter, float *multiplyResult)
	{
		const int size = before.size();

		//align arrays
		GetAlignedCloud(before, alignBefore);
		
		auto permutationIteratorBegin = thrust::make_permutation_iterator(after.begin(), permutation.begin());
		auto permutationIteratorEnd = thrust::make_permutation_iterator(after.end(), permutation.end());
		thrust::copy(thrust::device, permutationIteratorBegin, permutationIteratorEnd, alignAfter.begin());
		GetAlignedCloud(alignAfter, alignAfter);

		//create array AFTER (transposed)
		auto countingBegin = thrust::make_counting_iterator<int>(0);
		auto countingEnd = thrust::make_counting_iterator<int>(size);
		auto zipBegin = thrust::make_zip_iterator(thrust::make_tuple(countingBegin, alignAfter.begin()));
		auto zipEnd = thrust::make_zip_iterator(thrust::make_tuple(countingEnd, alignAfter.end()));

		auto convertAfter = Functors::GlmToCuBlas(true, size, workAfter);
		thrust::for_each(thrust::device, zipBegin, zipEnd, convertAfter);

		//create array BEFORE
		const auto beforeZipBegin = thrust::make_zip_iterator(thrust::make_tuple(countingBegin, alignBefore.begin()));
		const auto beforeZipEnd = thrust::make_zip_iterator(thrust::make_tuple(countingEnd, alignBefore.end()));
		auto convertBefore = Functors::GlmToCuBlas(false, before.size(), workBefore);
		thrust::for_each(thrust::device, beforeZipBegin, beforeZipEnd, convertBefore);

		//multiply
		CuBlasMultiply(workBefore, workAfter, multiplyResult, size);
		
		return glm::mat4(1);
	}

	glm::mat4 CudaICP(const Cloud& before, const Cloud& after)
	{
		const int maxIterations = 60;
		const float TEST_EPS = 1e-5;

		int iterations = 0;
		glm::mat4 transformationMatrix(1.0f);

		//do not change before vector - copy it for calculations
		Cloud workingBefore(before.size());
		Cloud alignBefore(before.size());
		Cloud alignAfter(before.size());
		thrust::copy(thrust::device, before.begin(), before.end(), workingBefore.begin());

		//allocate memory for cuBLAS
		float * tempBefore = nullptr, * tempAfter = nullptr, * result = nullptr;
		cudaMalloc(&tempBefore, before.size() * 3 * sizeof(float));
		cudaMalloc(&tempAfter, before.size() * 3 * sizeof(float));
		cudaMalloc(&result, 3 * 3 * sizeof(float));

		while (iterations < maxIterations)
		{
			auto correspondingPoints = GetCorrespondingPoints(workingBefore, after);

			transformationMatrix = LeastSquaresSVD(correspondingPoints, workingBefore, after, alignBefore, alignAfter, tempBefore, tempAfter, result) * transformationMatrix;

			TransformCloud(before, workingBefore, transformationMatrix);
			float error = GetMeanSquaredError(correspondingPoints, workingBefore, after);
			printf("Iteration: %d, error: %f\n", iterations, error);
			if (error < TEST_EPS)
				break;

			iterations++;
		}

		cudaFree(tempBefore);
		cudaFree(tempAfter);
		cudaFree(result);
		return transformationMatrix;
	}

	void CorrespondencesTest()
	{
		const int size = 100;
		thrust::device_vector<glm::vec3> input(size);
		thrust::device_vector<glm::vec3> output(size);
		for (int i = 0; i < size; i++)
		{
			const auto vec = glm::vec3(i);
			input[i] = vec;
			output[size - i - 1] = vec;
		}

		auto result = GetCorrespondingPoints(input, output);
		thrust::host_vector<int> copy = result;
		bool ok = true;
		for (int i = 0; i < size; i++)
			if (copy[i] != size - i - 1)
				ok = false;

		printf("Correspondence test [%s]\n", ok ? "OK" : "FAILED");
	}

	void MultiplicationTest()
	{
		const int size = 100;
		float * A = nullptr, * B = nullptr, * C = nullptr;
		cudaMalloc(&A, size * 3 * sizeof(float));
		cudaMalloc(&B, size * 3 * sizeof(float));
		cudaMalloc(&C, 3 * 3 * sizeof(float));

		float ones[3 * size];
		for (int i = 0; i < 3 * size; i++)
			ones[i] = 1.f;

		cudaMemcpy(A, ones, 3 * size * sizeof(float), cudaMemcpyHostToDevice);
		cudaMemcpy(B, ones, 3 * size * sizeof(float), cudaMemcpyHostToDevice);

		CuBlasMultiply(A, B, C, size);

		float result[9];
		cudaMemcpy(result, C, 9 * sizeof(float), cudaMemcpyDeviceToHost);

		bool ok = true;
		for (int i = 0; i < 9; i++)
			if (abs(result[i] - size) > 1e-5)
				ok = false;

		printf("Multiplication test [%s]\n", ok ? "OK" : "FAILED");

		cudaFree(A);
		cudaFree(B);
		cudaFree(C);
	}
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
	const auto hostCloud = CommonToThrustVector(testCloud);

	Cloud deviceCloudBefore = hostCloud;
	Cloud deviceCloudAfter(deviceCloudBefore.size());
	Cloud calculatedCloud(deviceCloudBefore.size());

	const auto scaleInput = Functors::ScaleTransform(100.f);
	thrust::transform(thrust::device, deviceCloudBefore.begin(), deviceCloudBefore.end(), deviceCloudBefore.begin(), scaleInput);

	const auto sampleTransform = glm::translate(glm::rotate(glm::mat4(1.f), glm::radians(20.f), { 0.5f, 0.5f, 0.f }), { 5.f, 5.f, 0.f });
	TransformCloud(deviceCloudBefore, deviceCloudAfter, sampleTransform);

	const auto result = CudaICP(deviceCloudBefore, deviceCloudAfter);
	TransformCloud(deviceCloudBefore, calculatedCloud, result);

	Common::Renderer renderer(
			Common::ShaderType::SimpleModel,
			ThrustToCommonVector(deviceCloudBefore), //grey
			ThrustToCommonVector(deviceCloudAfter), //blue
			ThrustToCommonVector(calculatedCloud), //red
			std::vector<Point_f>(1));

	renderer.Show();
}
