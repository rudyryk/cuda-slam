#include <Eigen/Dense>

#include "common.h"
#include "loader.h"

namespace Common 
{
	namespace
	{
		constexpr float TEST_EPS = 1e-6f;

		float GetRandomFloat(float min, float max)
		{
			float range = max - min;
			return static_cast<float>(rand()) / RAND_MAX * range + min;
		}

		Point_f GetRandomPoint(const Point_f& min, const Point_f& max)
		{
			return {
				GetRandomFloat(min.x, max.x),
				GetRandomFloat(min.y, max.y),
				GetRandomFloat(min.z, max.z)
			};
		}

		Point_f TransformPoint(const Point_f& in, const glm::mat4& matrix)
		{
			const glm::vec3 result = matrix * glm::vec4(glm::vec3(in), 1.0f);
			return Point_f(result);
		}
	}

	std::vector<Point_f> LoadCloud(const std::string& path)
	{
		AssimpCloudLoader loader(path);
		if (loader.GetCloudCount() > 0)
			return loader.GetCloud(0);
		else
			return std::vector<Point_f>();
	}

	glm::mat4 GetTransform(glm::mat3 forSvd, glm::vec3 before, glm::vec3 after)
	{
		//// Official documentation says thin U and thin V are enough for us, not gonna argue
		//// But maybe it is not enough
		Eigen::Matrix3f matrix;
		for (int i = 0; i < 3; i++)
			for (int j = 0; j < 3; j++)
				matrix(i, j) = forSvd[j][i];

		Eigen::JacobiSVD<Eigen::Matrix3f> const svd(matrix, Eigen::ComputeFullU | Eigen::ComputeFullV);

		double det = (svd.matrixU() * svd.matrixV().transpose()).determinant();
		Eigen::Matrix3f diag = Eigen::DiagonalMatrix<float, 3>(1, 1, det);
		Eigen::Matrix3f rotation = svd.matrixU() * diag * svd.matrixV().transpose();

		glm::mat4 transformationMatrix(0);
		for (int i = 0; i < 3; i++)
		{
			for (int j = 0; j < 3; j++)
			{
				transformationMatrix[i][j] = rotation(j, i);
			}
			transformationMatrix[i][3] = 0;
		}

		Eigen::Vector3f beforep{ before.x, before.y, before.z };
		Eigen::Vector3f afterp{ after.x, after.y, after.z };
		Eigen::Vector3f translation = afterp - (rotation * beforep);

		transformationMatrix[3][0] = translation.x();
		transformationMatrix[3][1] = translation.y();
		transformationMatrix[3][2] = translation.z();
		transformationMatrix[3][3] = 1.0f;
		return transformationMatrix;
	}

	std::vector<Point_f> GetRandomPointCloud(const Point_f& corner, const Point_f& size, int count)
	{
		std::vector<Point_f> result;
		for (int i = 0; i < count; i++)
			result.push_back(GetRandomPoint(corner, corner + size));

		return result;
	}

	glm::mat4 GetRandomTransformMatrix(const Point_f& translationMin, const Point_f& translationMax, float rotationRange)
	{
		const auto rotation = glm::rotate(glm::mat4(1.0f),
			GetRandomFloat(0, rotationRange),
			glm::vec3(GetRandomPoint(Point_f::Zero(), Point_f::One())));

		return glm::translate(rotation, glm::vec3(GetRandomPoint(translationMin, translationMax)));
	}

	std::vector<Point_f> GetTransformedCloud(const std::vector<Point_f>& cloud, const glm::mat4& matrix)
	{
		auto clone = cloud;
		std::transform(clone.begin(), clone.end(), clone.begin(), [&](Point_f p) { return TransformPoint(p, matrix); });
		return clone;
	}

	std::vector<Point_f> ApplyPermutation(const std::vector<Point_f>& input, const std::vector<int>& permutation)
	{
		std::vector<Point_f> permutedCloud(input.size());
		for (int i = 0; i < input.size(); i++)
			permutedCloud[i] = input[permutation[i]];

		return permutedCloud;
	}

	Point_f GetCenterOfMass(const std::vector<Point_f> & cloud)
	{
		return std::accumulate(cloud.begin(), cloud.end(), Point_f::Zero()) / (float)cloud.size();
	}

	float GetMeanSquaredError(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter, const glm::mat4& matrix)
	{
		float diffSum = 0.0f;
		// We assume clouds are the same size but if error is significant, you might want to check it
		for (int i = 0; i < cloudBefore.size(); i++)
		{
			const auto transformed = TransformPoint(cloudBefore[i], matrix);
			const auto diff = cloudAfter[i] - transformed;
			diffSum += (diff.Length() * diff.Length());
		}

		return diffSum / cloudBefore.size();
	}

	bool TestTransformOrdered(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter, const glm::mat4& matrix)
	{
		if (cloudBefore.size() != cloudAfter.size())
			return false;
		return GetMeanSquaredError(cloudBefore, cloudAfter, matrix) <= TEST_EPS;
	}

	bool TestTransformWithPermutation(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter, const std::vector<int>& permutation, const glm::mat4& matrix)
	{
		const auto permutedCloudBefore = ApplyPermutation(cloudBefore, permutation);
		return TestTransformOrdered(permutedCloudBefore, cloudAfter, matrix);
	}

	bool TestPermutation(const std::vector<int>& expected, const std::vector<int>& actual)
	{
		return actual == expected;
	}

	std::vector<int> GetRandomPermutationVector(int size)
	{
		std::vector<int> permutation(size);
		std::iota(permutation.begin(), permutation.end(), 0);
		std::shuffle(permutation.begin(), permutation.end(), std::mt19937{ std::random_device{}() });
		return permutation;
	}

	std::vector<int> GetClosestPointIndexes(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter)
	{
		const auto size = cloudBefore.size();
		std::vector<int> resultPermutation(size);
		std::vector<float> bestLength(size, std::numeric_limits<float>::max());

		for (int i = 0; i < size; i++)
		{
			for (int j = 0; j < size; j++)
			{
				float length = (cloudAfter[j] - cloudBefore[i]).LengthSquared();

				if (length < bestLength[i])
				{
					bestLength[i] = length;
					resultPermutation[i] = j;
				}
			}
		}

		return resultPermutation;
	}

	std::vector<int> InversePermutation(const std::vector<int>& permutation)
	{
		auto inversedPermutation = std::vector<int>(permutation.size());
		for (int i = 0; i < permutation.size(); i++)
		{
			inversedPermutation[permutation[i]] = i;
		}

		return inversedPermutation;
	}

	std::pair<std::vector<Point_f>, std::vector<Point_f>>GetClosestPointPair(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter)
	{
		auto permutation = GetClosestPointIndexes(cloudBefore, cloudAfter);
		auto orderedCloudAfter = ApplyPermutation(cloudAfter, permutation);

		return std::make_pair(cloudBefore, orderedCloudAfter);
	}

	std::vector<Point_f> GetAlignedCloud(const std::vector<Point_f>& cloud)
	{
		auto center = GetCenterOfMass(cloud);
		auto result = std::vector<Point_f>(cloud.size());
		// TODO: Use thrust maybe and parametrize host/device run
		std::transform(cloud.begin(), cloud.end(), result.begin(),
			[center](const Point_f& point) -> Point_f { return point - center; });

		return result;
	}

	Eigen::Matrix3Xf GetMatrix3XFromPointsVector(const std::vector<Point_f>& points)
	{
		Eigen::Matrix3Xf result = Eigen::ArrayXXf::Zero(3, points.size());

		// TODO: We can do it more elegant way for sure (probably assignment to a row)
		for (int i = 0; i < points.size(); i++)
		{
			result(0, i) = points[i].x;
			result(1, i) = points[i].y;
			result(2, i) = points[i].z;
		}

		return result;
	}

	glm::mat4 LeastSquaresSVD(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& orderedCloudAfter, const Point_f& cBefore, const Point_f& cAfter)
	{
		auto transformationMatrix = glm::mat4();
		auto alignedBefore = GetAlignedCloud(cloudBefore);
		auto alignedAfter = GetAlignedCloud(orderedCloudAfter);

		Eigen::MatrixXf matrix = GetMatrix3XFromPointsVector(alignedBefore) * GetMatrix3XFromPointsVector(alignedAfter).transpose();

		// Official documentation says thin U and thin V are enough for us, not gonna argue
		// But maybe it is not enough, delete flags then
		Eigen::JacobiSVD svd(matrix, Eigen::ComputeFullU | Eigen::ComputeFullV);

		Eigen::Matrix3f vMatrix = svd.matrixV();
		Eigen::Matrix3f uMatrix = svd.matrixU();

		Eigen::Matrix3f uv = uMatrix * vMatrix.transpose();
		auto diag = Eigen::DiagonalMatrix<float, 3>(1, 1, uv.determinant());
		auto rotation = uMatrix * diag * vMatrix.transpose();

		Point_f translation = { 0, 0, 0 };// cAfter - rotation * cBefore;

		// TODO: Do something with interaction between glm and eigen
		for (int i = 0; i < 3; i++)
		{
			for (int j = 0; j < 3; j++)
				transformationMatrix[j][i] = rotation(i, j);
		}
		transformationMatrix[2][3] = 0;
		transformationMatrix[3][0] = translation.x;
		transformationMatrix[3][1] = translation.y;
		transformationMatrix[3][2] = translation.z;
		transformationMatrix[3][3] = 1;

		return transformationMatrix;
	}

	glm::mat4 GetTransformationMatrix(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter, int *iterations, float *error, int maxIterations = -1)
	{
		glm::mat4 transformationMatrix(1.0f);
		std::pair<std::vector<Point_f>, std::vector<Point_f>> closestPoints;
		*iterations = 0;
		*error = 1.0f;

		do
		{
			auto transformedCloud = GetTransformedCloud(cloudBefore, transformationMatrix);
			closestPoints = GetClosestPointPair(transformedCloud, cloudAfter);

			auto centroidBefore = GetCenterOfMass(transformedCloud);
			auto centroidAfter = GetCenterOfMass(cloudAfter);
			
			transformationMatrix = LeastSquaresSVD(closestPoints.first, closestPoints.second, centroidBefore, centroidAfter);
			transformedCloud = GetTransformedCloud(cloudBefore, transformationMatrix);
			closestPoints = GetClosestPointPair(transformedCloud, cloudAfter);

			*error = GetMeanSquaredError(cloudBefore, closestPoints.second, transformationMatrix);
			printf("Iteration: %d, MSE: %f\n", *iterations, *error);
			(*iterations)++;

		} while (*error > TEST_EPS && *iterations <= maxIterations);

		return transformationMatrix;
	}

	void LibraryTest()
	{
		srand(666);
		const Point_f corner = { -1, -1, -1 };
		const Point_f size = { 2, 2, 2 };
		int iterations = 0;
		float error = 1.0f;

		//const auto cloud = GetRandomPointCloud(corner, size, 3000);
		auto cloud = LoadCloud("data/bunny.obj");

		std::transform(cloud.begin(), cloud.end(), cloud.begin(), [](const Point_f& point) { return Point_f { point.x * 100.f, point.y * 100.f, point.z * 100.f }; });
		cloud.resize(3000);
		int cloudSize = cloud.size();

		const auto transform = glm::translate(glm::mat4(1.f), { 1.f, 1.f, 0.f }); //GetRandomTransformMatrix({ 0.f, 0.f, 0.f }, { 0.1, 0.1, 0.1 }, glm::radians(0.f));
		const auto permutation = GetRandomPermutationVector(cloudSize);
		const auto permutedCloud = ApplyPermutation(cloud, permutation);
		const auto transformedCloud = GetTransformedCloud(cloud, transform);
		const auto transformedPermutedCloud = GetTransformedCloud(permutedCloud, transform);

		const auto calculatedPermutation = InversePermutation(GetClosestPointIndexes(cloud, transformedPermutedCloud));
		const auto icpCalculatedTransform1 = GetTransformationMatrix(cloud, transformedPermutedCloud, &iterations, &error, 4);
		//const auto icpCalculatedTransform2 = GetTransformationMatrix(cloud, transformedPermutedCloud, &iterations, &error);

		const auto resultOrdered = TestTransformOrdered(cloud, transformedCloud, transform);
		const auto resultUnordered = TestTransformWithPermutation(cloud, transformedPermutedCloud, permutation, transform);
		const auto resultPermutation = TestPermutation(permutation, calculatedPermutation);

		printf("Ordered cloud test [%s]\n", resultOrdered ? "OK" : "FAIL");
		printf("Unordered cloud test [%s]\n", resultUnordered ? "OK" : "FAIL");
		printf("Permutation find test [%s]\n", resultPermutation ? "OK" : "FAIL");
		printf("ICP test (%d iterations) error = %g\n", iterations, error);


		Common::Renderer renderer(
			Common::ShaderType::SimpleModel,
			cloud, //grey
			transformedCloud, //blue
			GetTransformedCloud(cloud, icpCalculatedTransform1), //red
			//GetTransformedCloud(cloud, icpCalculatedTransform1)); //green
			std::vector<Point_f>(1));

		renderer.Show();
	}
}
