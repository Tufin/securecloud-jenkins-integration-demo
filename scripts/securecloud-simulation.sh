#!/bin/bash

PrintUsage() {
	echo ""
	echo "Usage: securecloud-simulation.sh <terraformFileName> <tufinResultsFileName>"
	echo ""
	echo "Mandatory environment variables:"
	echo "  TUFIN_SECURECLOUD_URL     - Tufin SecureCloud URL \"https://<your-account>.securecloud.tufin.io\""
	echo "  TUFIN_SECURECLOUD_API_KEY - API key to Tufin SecureCloud with global admin permissions"
	echo ""
	echo "Mandatory arguments"
	echo "  terraformFileName      - Name of Terraform plan file"
	echo "  tufinResultsFileName   - Name of file where simulation results will be saved"
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
	planFileName="$1"
	resultsFileName="$2"

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

	if [[ -z "${planFileName}" ]]; then
		echo "ERROR: Please provide Terraform plan filename"
		PrintUsage
		exit 1
	fi

	if [[ ! -f "${planFileName}" ]]; then
		echo "ERROR: Terraform plan file does not exist: ${planFileName}"
		PrintUsage
		exit 1
	fi

	if [[ -z "${resultsFileName}" ]]; then
		echo "ERROR: Please provide simulation results filename to create"
		PrintUsage
		exit 1
	fi
}

StartSimulation() {
  simulateUrl="${TUFIN_SECURECLOUD_URL}/api/iris/model/cross-account/simulation"
  headersFile="${WORKSPACE}/headers.json"
	code=$(curl -s -D "${headersFile}" -w "%{response_code}" --request POST -H "Authorization: Bearer ${TUFIN_SECURECLOUD_API_KEY}" --header 'Format: terraform02' --form "plan=@${planFileName}" "${simulateUrl}")

  if [[ "${code}" -ne "202" ]]; then
	  echo "ERROR: SecureCloud HTTP response status code was ${code}"
	  exit 1
	fi

	if [[ ! -f "${headersFile}" ]]; then
		echo "ERROR: Terraform plan file does not exist: ${planFileName}"
		exit 1
	fi
}

WaitForResults() {
  simulationResultsUrl=`grep "^location" ${headersFile}  | cut -d":" -f2- | tr -d '[:space:]'`
  if [[ -z "${simulationResultsUrl}" ]]; then
		echo "ERROR: Failed to get location from headers file"
		exit 1
	fi

  wait_count="60"
  i="0"
  while [[ "$i" -lt "$wait_count" ]]; do
    printf .
    sleep 2
    curl --request GET -H "Authorization: Bearer ${TUFIN_SECURECLOUD_API_KEY}" -o "${resultsFileName}" "${simulationResultsUrl}"
    status=$(jq -r '.status' "${resultsFileName}")
    if [[ "${status^^}" == "SUCCESS" ]]; then
      break
    elif [[ "${status^^}" != "IN_PROGRESS" ]]; then
      echo "Unknown status found: ${status}"
      exit 1
    fi
    i=$[$i+1]
  done
  echo ""

  if [[ "$i" -eq "$wait_count" ]]; then
    echo "Failed to get simulation results after ${wait_count} attempts"
    exit 1
  fi
}

AnalyzeResults() {
  violationsCount=`jq -r '.result[]? | length' "${resultsFileName}"`
  if [[ ${violationsCount} -gt 0 ]]; then
    worseStatesCount=$(jq -r '.result.asset_violation_diffs[].state' "${resultsFileName}" | egrep -i "(NEW|ESCALATION|CHANGE)" | wc -l)
    if [[ ${worseStatesCount} -gt 0 ]]; then
      printViolations
      exit 1
    else
      echo "No violation in either NEW, ESCALATION or CHANGE state"
    fi
  else
    echo "No violation found"
  fi
}

printViolations() {
  toPrint=$(cat ${resultsFileName} | jq)
  echo "Found violations: ${toPrint}"
}

#---------------------------------------------------------------------------------------------------------------

exitCode=0
ValidateDependencies "curl" "jq"
ValidateUsage $@
StartSimulation
WaitForResults
AnalyzeResults
exit $exitCode



