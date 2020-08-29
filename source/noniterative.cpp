#include <Eigen/Dense>

#include "noniterative.h"
#include "timer.h"
#include "configuration.h"
#include "nicputils.h"

#include <thread>

using namespace Common;

namespace NonIterative
{
	constexpr auto NICP_EPS = 1e-5;

	std::pair<glm::mat3, glm::vec3> CalculateNonIterativeWithConfiguration(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter, Common::Configuration config)
	{
		auto maxIterations = config.MaxIterations.has_value() ? config.MaxIterations.value() : -1;

		auto parallel = config.ExecutionPolicy.has_value() ?
			config.ExecutionPolicy.value() == Common::ExecutionPolicy::Parallel :
			true;

		int repetitions = 0;
		float error = 0;

		auto result = GetNonIterativeTransformationMatrix(cloudBefore, cloudAfter, &repetitions, &error, NICP_EPS, maxIterations, config.ApproximationType, parallel);
		return result;
	}

	NonIterativeSlamResult GetSingleNonIterativeSlamResult(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter)
	{
		glm::mat3 rotationMatrix = glm::mat3(1.0f);
		glm::vec3 translationVector = glm::vec3(0.0f);
		std::vector<Point_f> transformedCloud = cloudBefore;

		Point_f centerBefore = GetCenterOfMass(cloudBefore);
		Point_f centerAfter = GetCenterOfMass(cloudAfter);

		std::vector<Point_f> alignedBefore = GetAlignedCloud(cloudBefore, centerBefore);
		std::vector<Point_f> alignedAfter = GetAlignedCloud(cloudAfter, centerAfter);

		Eigen::Matrix3Xf matrixBefore = GetMatrix3XFromPointsVector(alignedBefore);
		Eigen::Matrix3Xf matrixAfter = GetMatrix3XFromPointsVector(alignedAfter);

		//const Eigen::JacobiSVD<Eigen::Matrix3Xf> svdBefore = Eigen::JacobiSVD<Eigen::Matrix3Xf>(matrixBefore, Eigen::ComputeFullU | Eigen::ComputeFullV);
		const Eigen::JacobiSVD<Eigen::Matrix3Xf> svdBefore = Eigen::JacobiSVD<Eigen::Matrix3Xf>(matrixBefore, Eigen::ComputeThinU | Eigen::ComputeThinV);
		Eigen::Matrix3f uMatrixBeforeTransposed = svdBefore.matrixU().transpose();

		//const Eigen::JacobiSVD<Eigen::Matrix3Xf> svdAfter = Eigen::JacobiSVD<Eigen::Matrix3Xf>(matrixAfter, Eigen::ComputeFullU | Eigen::ComputeFullV);
		const Eigen::JacobiSVD<Eigen::Matrix3Xf> svdAfter = Eigen::JacobiSVD<Eigen::Matrix3Xf>(matrixAfter, Eigen::ComputeThinU | Eigen::ComputeThinV);
		Eigen::Matrix3f uMatrixAfter = svdAfter.matrixU();

		Eigen::Matrix3f rotation = uMatrixAfter * uMatrixBeforeTransposed;

		rotationMatrix = ConvertRotationMatrix(rotation);
		translationVector = glm::vec3(centerAfter) - (rotationMatrix * centerBefore);

		float error = GetMeanSquaredError(alignedBefore, alignedAfter, rotationMatrix);
		return NonIterativeSlamResult(rotationMatrix, translationVector, error);
	}

	std::pair<glm::mat3, glm::vec3> GetNonIterativeTransformationMatrixParallel(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter, int *repetitions, float* error, float eps, int maxRepetitions, const ApproximationType& calculationType, int subcloudSize)
	{
		std::pair<glm::mat3, glm::vec3> bestTransformation;
		
		//TODO: implement
		/*float minError = std::numeric_limits<float>::max();

		// Get subcloud for comparison
		if (subcloudSize == -1)
			subcloudSize = cloudBefore.size();

		std::vector<int> subcloudIndices = GetRandomPermutationVector(subcloudSize);
		std::vector<Point_f>subcloudVertices = GetSubcloud(cloudBefore, subcloudIndices);
		const float maxDistanceForComparison = 1e6;
		*repetitions = maxRepetitions;

		const auto threadCount = std::thread::hardware_concurrency();
		
		const auto work_thread = [&](float* error, glm::mat3* rotation, glm::vec3* translation) {
			const auto permutationBefore = GetRandomPermutationVector(cloudBefore.size());
			const auto permutationAfter = GetRandomPermutationVector(cloudAfter.size());
			const auto permutedBefore = ApplyPermutation(cloudBefore, permutationBefore);
			const auto permutedAfter = ApplyPermutation(cloudAfter, permutationAfter);
		};

		
		// Run NonIterative SLAM for multiple permutations and return the best fit
		std::vector<NonIterativeSlamResult> bestResults;
		for (int i = 0; i < maxRepetitions; i++)
		{

			NonIterativeSlamResult transformationResult = GetSingleNonIterativeSlamResult(permutedBefore, permutedAfter);
			*error = transformationResult.getApproximatedError();
			// If not using approximation, calculate error for selected subcloud
			if (calculationType == ApproximationType::None)
			{
				std::vector<Point_f> transformedSubcloud = GetTransformedCloud(subcloudVertices, transformationResult.getRotationMatrix(), transformationResult.getTranslationVector());
				CorrespondingPointsTuple correspondingPoints = GetCorrespondingPoints(transformedSubcloud, permutedAfter, maxDistanceForComparison, true);
				*error = GetMeanSquaredError(std::get<0>(correspondingPoints), std::get<1>(correspondingPoints));

				if (*error < minError)
				{
					minError = *error;
					bestTransformation = transformationResult.getTransformation();

					if (minError <= eps)
					{
						return bestTransformation;
					}
				}
			}
			// If using hybrid approximation, select 5 best fits for further analysis
			else if (calculationType == ApproximationType::Hybrid)
			{
				StoreResultIfOptimal(bestResults, transformationResult, 5);
			}
			// If using full approximation, select the best result for further error calculation
			else if(calculationType == ApproximationType::Full)
			{
				StoreResultIfOptimal(bestResults, transformationResult, 1);
			}
		}

		// If using hybrid approximation, select best result
		// If using full approximation, calculate exact error for the best result
		if (calculationType != ApproximationType::None)
		{
			minError = std::numeric_limits<float>::max();
			for (int i = 0; i < bestResults.size(); i++)
			{
				std::vector<Point_f> transformedSubcloud = GetTransformedCloud(subcloudVertices, bestResults[i].getRotationMatrix(), bestResults[i].getTranslationVector());
				CorrespondingPointsTuple correspondingPoints = GetCorrespondingPoints(transformedSubcloud, bestResults[i].getCloudAfter(), maxDistanceForComparison, true);
				*error = GetMeanSquaredError(std::get<0>(correspondingPoints), std::get<1>(correspondingPoints));

				if (*error < minError)
				{
					minError = *error;
					bestTransformation = bestResults[i].getTransformation();

					if (minError <= eps)
					{
						return bestTransformation;
					}
				}
			}
		}

		*error = minError; */
		return bestTransformation;
	}

	std::pair<glm::mat3, glm::vec3> GetNonIterativeTransformationMatrixSequential(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter, int* repetitions, float* error, float eps, int maxRepetitions, const ApproximationType& calculationType, int subcloudSize)
	{
		int cloudSize = std::min(cloudBefore.size(), cloudAfter.size());

		std::pair<glm::mat3, glm::vec3> bestTransformation;
		float minError = std::numeric_limits<float>::max();

		// Get subcloud for comparison
		std::vector<Point_f>subcloudVertices = GetSubcloud(cloudBefore, subcloudSize);
		const float maxDistanceForComparison = 1e6;

		// Run NonIterative SLAM for multiple permutations and return the best fit
		std::vector<NonIterativeSlamResult> bestResults;
		for (int i = 0; i < maxRepetitions; i++)
		{
			const auto permutation = GetRandomPermutationVector(cloudSize);
			const auto permutedBefore = ApplyPermutation(cloudBefore, permutation);
			const auto permutedAfter = ApplyPermutation(cloudAfter, permutation);

			NonIterativeSlamResult transformationResult = GetSingleNonIterativeSlamResult(permutedBefore, permutedAfter);
			*error = transformationResult.getApproximatedError();
			// If not using approximation, calculate error for selected subcloud
			if (calculationType == ApproximationType::None)
			{
				std::vector<Point_f> transformedSubcloud = GetTransformedCloud(subcloudVertices, transformationResult.getRotationMatrix(), transformationResult.getTranslationVector());
				CorrespondingPointsTuple correspondingPoints = GetCorrespondingPoints(transformedSubcloud, permutedAfter, maxDistanceForComparison, true);
				*error = GetMeanSquaredError(std::get<0>(correspondingPoints), std::get<1>(correspondingPoints));

				if (*error < minError)
				{
					minError = *error;
					bestTransformation = transformationResult.getTransformation();

					if (minError <= eps)
					{
						*repetitions = i;
						return bestTransformation;
					}
				}
			}
			// If using hybrid approximation, select 5 best fits for further analysis
			else if (calculationType == ApproximationType::Hybrid)
			{
				StoreResultIfOptimal(bestResults, transformationResult, 5);
			}
			// If using full approximation, select the best result for further error calculation
			else if(calculationType == ApproximationType::Full)
			{
				StoreResultIfOptimal(bestResults, transformationResult, 1);
			}
		}

		// If using hybrid approximation, select best result
		// If using full approximation, calculate exact error for the best result
		if (calculationType != ApproximationType::None)
		{
			minError = std::numeric_limits<float>::max();
			for (int i = 0; i < bestResults.size(); i++)
			{
				std::vector<Point_f> transformedSubcloud = GetTransformedCloud(subcloudVertices, bestResults[i].getRotationMatrix(), bestResults[i].getTranslationVector());
				CorrespondingPointsTuple correspondingPoints = GetCorrespondingPoints(transformedSubcloud, cloudAfter, maxDistanceForComparison, false);
				*error = GetMeanSquaredError(std::get<0>(correspondingPoints), std::get<1>(correspondingPoints));

				if (*error < minError)
				{
					minError = *error;
					bestTransformation = bestResults[i].getTransformation();

					if (minError <= eps)
					{
						return bestTransformation;
					}
				}
			}
		}

		*error = minError;
		return bestTransformation;
	}

	std::pair<glm::mat3, glm::vec3> GetNonIterativeTransformationMatrix(const std::vector<Point_f>& cloudBefore, const std::vector<Point_f>& cloudAfter, int *repetitions, float* error, float eps, int maxRepetitions, const ApproximationType& calculationType, bool parallel, int subcloudSize)
	{
		if (parallel)
			return GetNonIterativeTransformationMatrixParallel(cloudBefore, cloudAfter, repetitions, error, eps, maxRepetitions, calculationType, subcloudSize);
		else
			return GetNonIterativeTransformationMatrixSequential(cloudBefore, cloudAfter, repetitions, error, eps, maxRepetitions, calculationType, subcloudSize);
	}
}