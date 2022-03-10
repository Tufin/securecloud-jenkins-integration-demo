#!/bin/bash

PrintUsage() {
  echo ""
  echo "Usage: securechange-authorize-change.sh <ticketID> <terraformPlanFile> <scwResponseFile> <scTargetsFile> <scAuthRequestBody> <scAuthResponseFile>"
  echo ""
  echo "Mandatory environment variables:"
  echo "  TUFIN_SECURECLOUD_URL          - Tufin SecureCloud URL \"https://<your-account>.securecloud.tufin.io\""
  echo "  TUFIN_SECURECLOUD_API_KEY      - API key to Tufin SecureCloud with global admin permissions"
  echo "  TUFIN_SECURECHANGE_URL         - Tufin SecureChange URL"
  echo "  TUFIN_SECURECHANGE_CREDENTIALS - Tufin SecureChange credentials in the format of username:password"
  echo ""
  echo "Mandatory arguments"
  echo "  ticketId           - SecureChange ticket ID to authorize"
  echo "  terraformPlanFile  - Path to terraform plan file"
  echo "  scwResponseFile    - Path to temp file that will hold the response from SecureChangeWorkflow"
  echo "  scTargetsFile      - Path to temp file that will hold the possible target IDs from SecureCloud"
  echo "  scAuthRequestBody  - Path to temp file that will hold the request body sent to SecureCloud"
  echo "  scAuthResponseFile - Path to temp file that will hold the authorization response from SecureCloud"
}

ValidateDependencies() {
  tools=($@)
  for tool in "${tools[@]}"; do
    command -v ${tool} &>/dev/null
    if [[ $? != 0 ]]; then
      echo "ERROR: '${tool}' is required but wasn't found! please install it."
      exit 1
    fi
  done
}

ValidateUsage() {
  ticketID="$1"
  terraformPlanFile="$2"
  scwResponseFile="$3"
  scTargetsFile="$4"
  scAuthRequestBody="$5"
  scAuthResponseFile="$6"

  if [[ -z "${TUFIN_SECURECLOUD_URL}" ]]; then
    echo "ERROR: Please set TUFIN_SECURECLOUD_URL environment variable"
    ExitWithUsage
  fi

  if [[ -z "${TUFIN_SECURECLOUD_API_KEY}" ]]; then
    echo "ERROR: Please set TUFIN_SECURECLOUD_API_KEY environment variable"
    ExitWithUsage
  fi

  if [[ -z "${TUFIN_SECURECHANGE_URL}" ]]; then
    echo "ERROR: Please set TUFIN_SECURECHANGE_URL environment variable"
    ExitWithUsage
  fi

  if [[ -z "${TUFIN_SECURECHANGE_CREDENTIALS}" ]]; then
    echo "ERROR: Please set TUFIN_SECURECHANGE_CREDENTIALS environment variable"
    ExitWithUsage
  fi

  if [[ -z "${ticketID}" ]]; then
    echo "ERROR: Please provide a ticket ID to authorize"
    ExitWithUsage
  fi

  if [[ -z "${terraformPlanFile}" ]]; then
    echo "ERROR: Please provide terraform plan file"
    ExitWithUsage
  fi

  if [[ -z "${scwResponseFile}" ]]; then
    echo "ERROR: Please provide a tmp file to save SCW response"
    ExitWithUsage
  fi

  if [[ -z "${scTargetsFile}" ]]; then
    echo "ERROR: Please provide a tmp file to save SC targets"
    ExitWithUsage
  fi

  if [[ -z "${scAuthRequestBody}" ]]; then
    echo "ERROR: Please provide a tmp file to save SC authorization request body"
    ExitWithUsage
  fi

  if [[ -z "${scAuthResponseFile}" ]]; then
    echo "ERROR: Please provide a tmp file to save SC authorization response"
    ExitWithUsage
  fi
}

ExitWithUsage() {
  PrintUsage
  exit 1
}

GetTicketFromScw() {
  getTicketUrl="${TUFIN_SECURECHANGE_URL}/api/securechange/tickets/${ticketID}.json"
  echo "Getting ticket #${ticketID} from SecureChange. Calling API: ${getTicketUrl}"
  code=$(curl -s -k -w "%{response_code}" -u "${TUFIN_SECURECHANGE_CREDENTIALS}" -o "${scwResponseFile}" "${getTicketUrl}")
  if [[ "${code}" -ne "200" ]]; then
    echo "ERROR: SecureChange HTTP response status code was ${code}, URL: ${getTicketUrl}"
    exit 1
  fi
}

ExtractTicketData() {
  $(jq empty ${scwResponseFile})
  if [[ $? -ne 0 ]]; then
    echo "ERROR: SecureChange response is an invalid JSON file"
    exit 1
  fi

  targetsJqSelector='.ticket.steps.step[] | select(.name == "Suggest Target") | .tasks.task.fields.field.access_request.targets.target[]? | select(.external_uid) | .external_uid'
  scwTargets=$(jq "${targetsJqSelector}" "${scwResponseFile}" | paste -s -d',')

  sourcesJqSelector='.ticket.steps.step[] | select(.name == "Suggest Target") | .tasks.task.fields.field.access_request.sources.source[]? | [.ip_address, .cidr|tostring] | join("/")'
  readarray -t scwSources <<<"$(jq -r "${sourcesJqSelector}" "${scwResponseFile}")"

  destinationsJqSelector='.ticket.steps.step[] | select(.name == "Suggest Target") | .tasks.task.fields.field.access_request.destinations.destination[]? | [.ip_address, .cidr|tostring] | join("/")'
  readarray -t scwDestinations <<<"$(jq -r "${destinationsJqSelector}" "${scwResponseFile}")"

  isAnyJqSelector='.ticket.steps.step[] | select(.name == "Suggest Target") | .tasks.task.fields.field.access_request.services.service[]? | select(."@type"=="ANY")'
  anyServiceCount=$(jq -r "${isAnyJqSelector}" "${scwResponseFile}" | wc -l)
  if [[ anyServiceCount -eq 0 ]]; then
    servicesJqSelector='.ticket.steps.step[] | select(.name == "Suggest Target") | .tasks.task.fields.field.access_request.services.service[]? | [.protocol, .port|tostring] | @csv'
    readarray -t scwServicesCsv <<<"$(jq -r "${servicesJqSelector}" "${scwResponseFile}")"
  fi
}

FindTargetIds() {
  getTargetsUrl="${TUFIN_SECURECLOUD_URL}/iris/api/provisioning/targets"
  echo "Getting all possible target IDs from SecureCloud. Calling api: ${getTargetsUrl}"
  code=$(curl -s -k -w "%{response_code}" -H "Authorization: Bearer ${TUFIN_SECURECLOUD_API_KEY}" -o "${scTargetsFile}" "${getTargetsUrl}")
  if [[ "${code}" -ne "200" ]]; then
    echo "ERROR: SecureCloud HTTP response status code was ${code}, URL: ${getTargetsUrl}"
    exit 1
  fi

  targetIDsJqSelector=".targets[] | select(.azure_vnet_id==(${scwTargets})) | .id"
  readarray -t scTargetIDs <<<"$(jq -r "${targetIDsJqSelector}" "${scTargetsFile}")"
  if [[ ${#scTargetIDs[@]} -eq 0 ]]; then
    echo "ERROR: Did not find any target"
    exit 1
  else
    echo "Found a match to ${#scTargetIDs[@]} targets from SecureCloud"
  fi
}

PrepareAuthorizationBody() {
  authRequestBody='{"accesses":[{'
  AddTargets
  AddSources
  AddDestinations
  AddServices
  authRequestBody+=,'"comment": "Authorization request for ticket #'"${ticketID}"'"'
  authRequestBody+='}]}'
  echo "${authRequestBody}" > "${scAuthRequestBody}"
}

AddTargets() {
  authRequestBody+='"targets":['
  for i in ${!scTargetIDs[@]}; do
    authRequestBody+=$(jq -n --arg targetId "${scTargetIDs[$i]}" '{"id": $targetId, "type":"AZURE_VNET"}')
    if [[ ${#scTargetIDs[@]} -ne ${i}+1 ]]; then
      authRequestBody+=","
    fi
  done
  authRequestBody+="]"
}

AddSources() {
  authRequestBody+=',"source":['
  for i in ${!scwSources[@]}; do
    authRequestBody+=$(jq -n --arg ip "${scwSources[$i]}" '{"type":"IP", "ip":$ip}')
    if [[ ${#scwSources[@]} -ne ${i}+1 ]]; then
      authRequestBody+=','
    fi
  done
  authRequestBody+=']'
}

AddDestinations() {
  authRequestBody+=',"destination":['
  for i in ${!scwDestinations[@]}; do
    authRequestBody+=$(jq -n --arg ip "${scwDestinations[$i]}" '{"type":"IP", "ip":$ip}')
    if [[ ${#scwDestinations[@]} -ne ${i}+1 ]]; then
      authRequestBody+=','
    fi
  done
  authRequestBody+=']'
}

AddServices() {
  authRequestBody+=',"services":['
  if [[ anyServiceCount -eq 0 ]]; then
    for i in ${!scwServicesCsv[@]}; do
      protocol=$(echo "${scwServicesCsv[$i]}" | cut -d',' -f1 | cut -d"\"" -f2)
      port=$(echo "${scwServicesCsv[$i]}" | cut -d',' -f2 | cut -d"\"" -f2)
      authRequestBody+=$(jq -n --arg protocol "${protocol}" --arg port "${port}" '{"type":"TRANSPORT", "protocol":$protocol, "min_port":$port, "max_port":$port}')
      if [[ ${#scwServicesCsv[@]} -ne ${i}+1 ]]; then
        authRequestBody+=','
      fi
    done
  else
    authRequestBody+='{"type":"ANY_NETWORK"}'
  fi
  authRequestBody+=']'
}

PostAuthRequest() {
  postAuthUrl="${TUFIN_SECURECLOUD_URL}/api/iris/model/cross-account/integration/verify-changes"
  echo "Verifying changes with SecureCloud. Calling api: ${postAuthUrl}"
  code=$(curl -X POST -s -k -w "%{response_code}" -H "Authorization: Bearer ${TUFIN_SECURECLOUD_API_KEY}" --header 'Format: terraform02' -F "plan=@${terraformPlanFile}" -F "access-request=@${scAuthRequestBody}" -o "${scAuthResponseFile}" "${postAuthUrl}")

  if [[ "${code}" -ne "200" ]]; then
    echo "ERROR: SecureCloud HTTP response status code was ${code}, URL: ${postAuthUrl}"
    exit 1
  fi
}

ParseAuthorizationResponse() {
  status=$(jq -r '.status' "${scAuthResponseFile}")
  if [[ "${status^^}" == "PASS" ]]; then
    echo "SUCCESS: SecureCloud authorization completed with status: ${status}"
  else
    echo "ERROR: SecureCloud authorization completed with status: ${status}, for more details see ${scAuthResponseFile}"
    exit 1
  fi
}

#=====================================================================================================================================================

ValidateDependencies "curl" "jq"
ValidateUsage $@
GetTicketFromScw
ExtractTicketData
FindTargetIds
PrepareAuthorizationBody
PostAuthRequest
ParseAuthorizationResponse
