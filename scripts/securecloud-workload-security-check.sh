#!/bin/bash

PrintUsage() {
	echo ""
	echo "Usage: securecloud-workload-security-check.sh <inputFilename> <outputFilename> [failOnAnyRisk]"
	echo ""
	echo "Mandatory environment variables:"
	echo "  TUFIN_SECURECLOUD_URL     - Tufin SecureCloud URL \"https://<your-account>.securecloud.tufin.io\""
	echo "  TUFIN_SECURECLOUD_API_KEY - API key to Tufin SecureCloud with global admin permissions"
	echo ""
	echo "Mandatory arguments"
	echo "  inputFilename  - Kubernetes workloads yaml filename to inspect"
	echo "  outputFilename - Workload security check results filename to create"
	echo ""
	echo "Optional arguments"
	echo "  failOnAnyRisk  - Must be one of: 'true' or 'false', default is 'false'"
}

ValidateDependencies() {
	tools=($@)
	for tool in "${tools[@]}"
	do
		command -v ${tool} &> /dev/null
		if [[ $? != 0 ]]; then
			echo "ERROR: '${tool}' is required but wasn't found! please install it."
			exit 1
		fi
	done
}

ValidateUsage() {
  if [[ -z "${TUFIN_SECURECLOUD_URL}" ]]; then
		echo "ERROR: Please set TUFIN_SECURECLOUD_URL environment variable"
		PrintUsage
		exit 1
	fi

	if [[ -z "${TUFIN_SECURECLOUD_API_KEY}" ]]; then
		echo "ERROR: Please set TUFIN_SECURECLOUD_API_KEY environment variable"
		PrintUsage
		exit 1
	fi

	inputFilename="$1"
	outputFilename="$2"
	failOnAnyRisk="${3:-false}"

	if [[ -z "${inputFilename}" ]]; then
		echo "ERROR: Please provide Kubernetes workloads yaml filename to inspect"
		PrintUsage
		exit 1
	fi

	if [[ -z "${outputFilename}" ]]; then
		echo "ERROR: Please provide workload security check results filename to create"
		PrintUsage
		exit 1
	fi

	if [[ "${failOnAnyRisk}" != "true" && "${failOnAnyRisk}" != "false" ]]; then
		echo "ERROR: failOnAnyRisk argument must be one of 'true' or 'false'. Value provided was '${failOnAnyRisk}'"
		PrintUsage
		exit 1
	fi
}

InvokeSecureCloudApi() {
	url="${TUFIN_SECURECLOUD_URL}/api/v1/orca/model/cross-cluster/workload-risks"

	code=`curl -X POST -s -w "%{response_code}" $url -H "Authorization: Bearer ${TUFIN_SECURECLOUD_API_KEY}" -H "Content-Type: application/octet-stream" --data-binary @"${inputFilename}" -o "${outputFilename}"`

	if [[ "${code}" -ne "200" ]]; then
		echo "ERROR: SecureCloud HTTP response status code was ${code}"
		exit 1
	fi
}

AnalyzeResponse() {
	response=`cat "${outputFilename}"`
	workloadsCount=`jq '[.workloads[]] | length' "${outputFilename}"`
	containersCount=`jq '[.workloads[].containers?[]] | length' "${outputFilename}"`

	podSecurityContextRisks=`jq '[.workloads[].risks?[] | select(.exempted == false)] | unique' "${outputFilename}"`
	podSecurityContextRisksCount=`jq '[.workloads[].risks?[] | select(.exempted == false)] | unique | length' "${outputFilename}"`

	containerSecurityContextRisks=`jq '[.workloads[].containers?[].risks?[] | select(.exempted == false)] | unique' "${outputFilename}"`
	containerSecurityContextRisksCount=`jq '[.workloads[].containers?[].risks?[] | select(.exempted == false)] | unique | length' "${outputFilename}"`

	msg=""
	shortMsg=""
	if [[ "${podSecurityContextRisksCount}" -gt "0" ]]; then
		msg="${msg}${podSecurityContextRisksCount} Pod Security Context Risks: ${podSecurityContextRisks} \n"
		shortMsg="${shortMsg}${podSecurityContextRisksCount} Pod Security Context Risks\n"
	fi
	if [[ "${containerSecurityContextRisksCount}" -gt "0" ]]; then
		msg="${msg}${containerSecurityContextRisksCount} Container Security Context Risks: ${containerSecurityContextRisks} \n"
		shortMsg="${shortMsg}${containerSecurityContextRisksCount} Container Security Context Risks\n"
	fi
	if [[ -z "${msg}" ]]; then
		printf "SecureCloud workload security check full response:\n${response}\n"
		printf "SecureCloud workload security check for ${workloadsCount} workloads with ${containersCount} containers passed\n"
		exit 0
	else
		msg="${msg}Across ${workloadsCount} workloads with ${containersCount} containers\nSecureCloud workload security check full response:\n${response}\n"
		shortMsg="${shortMsg}Across ${workloadsCount} workloads with ${containersCount} containers\n"
		printf "SecureCloud workload security check found:\n${msg}\n"
		if [[ "${failOnAnyRisk}" != "false" ]]; then
			printf "ERROR: SecureCloud workload security check found:\n${shortMsg}\n"
			exit 1
		fi
	fi

}

TUFIN_SECURECLOUD_URL=${TUFIN_SECURECLOUD_URL:-"https://nir.securecloudtestnir.tufin.io"}
ValidateDependencies "curl" "jq"
ValidateUsage $@
InvokeSecureCloudApi
AnalyzeResponse
