#include "configparser.h"

#include <fstream>

namespace {
	constexpr const char* DEFAULT_PATH = "config/default.json";
}

namespace Common
{
	ConfigParser::ConfigParser(int argc, char** argv)
	{
		const std::string defaultPath = { DEFAULT_PATH };
		if (argc == 1)
		{
			printf("No config passed, loading: %s\n", DEFAULT_PATH);
			LoadConfigFromFile(defaultPath);
		}
		else if (argc == 2)
		{
			const std::string path = { argv[1] };
			if (std::filesystem::exists(path))
			{
				printf("Loading config from: %s\n", path.c_str());
				LoadConfigFromFile(path);
			}
			else
			{
				printf("File: %s does not exist, loading default config\n", path.c_str());
				LoadConfigFromFile(defaultPath);
			}
		}
		else
		{
			printf("Usage: %s (config_path)\n", argv[0]);
			printf("Loading default config\n");
			LoadConfigFromFile(defaultPath);
		}
	}

	void ConfigParser::LoadConfigFromFile(const std::string& path)
	{
		auto stream = std::ifstream(path);
		auto content = std::string((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
		stream.close();

		auto parsed = nlohmann::json::parse(content);
		ParseMethod(parsed);
		ParseCloudPaths(parsed);
	}

	void ConfigParser::ParseMethod(const nlohmann::json& parsed)
	{
		auto method = ParseRequired<std::string>(parsed, "method");
		if (!method.has_value())
			return;

		const std::map<std::string, ComputationMethod> mapping = {
			{ "icp", ComputationMethod::Icp },
			{ "nicp", ComputationMethod::NoniterativeIcp },
			{ "cpd", ComputationMethod::Cpd }
		};

		const auto methodStr = method.value();
		if (auto result = mapping.find(methodStr); result != mapping.end())
		{
			computationMethod = result->second;
		}
		else
		{
			printf("Parsing error: Computational method %s not supported\n", methodStr.c_str());
			correct = false;
		}
	}
		
	void ConfigParser::ParseCloudPaths(const nlohmann::json& parsed)
	{
		auto beforePathOpt = ParseRequired<std::string>(parsed, "before-path");
		auto afterPathOpt = ParseRequired<std::string>(parsed, "afger-path");
		if (!beforePathOpt.has_value() || !afterPathOpt.has_value())
			return;
	
		beforePath = beforePathOpt.value();
		afterPath = afterPathOpt.value();
	}
}
