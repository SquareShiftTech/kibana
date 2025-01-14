#!/bin/bash

fail() {
  printf "%s\n" "$@" >&2
  exit 1
}

if [ -z "${BASH_VERSION:-}" ]; then
  fail "Bash is requred to run this script"
fi

install_api_key_encoded=""
ingest_api_key_encoded=""
kibana_api_endpoint=""
onboarding_flow_id=""
elastic_agent_version=""

help() {
    echo "Usage: sudo ./auto-detect.sh <arguments>"
    echo ""
    echo "Arguments:"
    echo "  --install-key=<value>  Base64 Encoded API key that has priviledges to install integrations."
    echo "  --ingest-key=<value>   Base64 Encoded API key that has priviledges to ingest data."
    echo "  --kibana-url=<value>  Kibana API endpoint."
    echo "  --id=<value>   Onboarding flow ID."
    echo "  --ea-version=<value>   Elastic Agent version."
    exit 1
}

ensure_argument() {
    if [ -z "$1" ]; then
        echo "Error: Missing value for $2."
        help
    fi
}

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root."
    help
fi

# Parse command line arguments
for i in "$@"; do
    case $i in
        --install-key=*)
            shift
            install_api_key_encoded="${i#*=}"
            ;;
        --ingest-key=*)
            shift
            ingest_api_key_encoded="${i#*=}"
            ;;
        --kibana-url=*)
            shift
            kibana_api_endpoint="${i#*=}"
            ;;
        --id=*)
            shift
            onboarding_flow_id="${i#*=}"
            ;;
        --ea-version=*)
            shift
            elastic_agent_version="${i#*=}"
            ;;
        --help)
            help
            ;;
        *)
            echo "Unknown option: $i"
            help
            ;;
    esac
done

ensure_argument "$install_api_key_encoded" "--install-key"
ensure_argument "$ingest_api_key_encoded" "--ingest-key"
ensure_argument "$kibana_api_endpoint" "--kibana-url"
ensure_argument "$onboarding_flow_id" "--id"
ensure_argument "$elastic_agent_version" "--ea-version"

known_integrations_list_string=""
selected_known_integrations_array=()
selected_known_integrations_tsv_string=""
unknown_log_file_path_list_string=""
unknown_log_file_pattern_list_string=""
selected_unknown_log_file_pattern_array=()
excluded_options_string=""
selected_unknown_log_file_pattern_tsv_string=""
custom_log_file_path_list_tsv_string=""
install_integrations_api_body_string=""
elastic_agent_artifact_name=""
elastic_agent_config_path="/opt/Elastic/Agent/elastic-agent.yml"

OS="$(uname)"
ARCH="$(uname -m)"
os=linux
arch=x86_64
if [ "${OS}" == "Linux" ]; then
  if [ "${ARCH}" == "aarch64" ]; then
    arch=arm64
  fi
elif [ "${OS}" == "Darwin" ]; then
  os=darwin
  if [ "${ARCH}" == "arm64" ]; then
    arch=aarch64
  fi
  elastic_agent_config_path=/Library/Elastic/Agent/elastic-agent.yml
else
  fail "This script is only supported on linux and macOS"
fi

elastic_agent_artifact_name="elastic-agent-${elastic_agent_version}-${os}-${arch}"

update_step_progress() {
  local STEPNAME="$1"
  local STATUS="$2" # "incomplete" | "complete" | "disabled" | "loading" | "warning" | "danger" | "current"
  local MESSAGE=${3:-}
  local PAYLOAD=${4:-}
  local data=""
  if [ -z "$PAYLOAD" ]; then
    data="{\"status\":\"${STATUS}\", \"message\":\"${MESSAGE}\"}"
  else
    data="{\"status\":\"${STATUS}\", \"message\":\"${MESSAGE}\", \"payload\":${PAYLOAD}}"
  fi
  curl --request POST \
    --url "${kibana_api_endpoint}/internal/observability_onboarding/flow/${onboarding_flow_id}/step/${STEPNAME}" \
    --header "Authorization: ApiKey ${install_api_key_encoded}" \
    --header "Content-Type: application/json" \
    --header "kbn-xsrf: true" \
    --header "x-elastic-internal-origin: Kibana" \
    --data "$data" \
    --output /dev/null \
    --no-progress-meter
}

download_elastic_agent() {
  local download_url="https://artifacts.elastic.co/downloads/beats/elastic-agent/${elastic_agent_artifact_name}.tar.gz"
  curl -L -O $download_url --fail

  if [ "$?" -eq 0 ]; then
    update_step_progress "ea-download" "complete"
  else
    update_step_progress "ea-download" "danger" "Failed to download Elastic Agent, see script output for error."
    fail "Failed to download Elastic Agent"
  fi
}

extract_elastic_agent() {
  tar -xzf "${elastic_agent_artifact_name}.tar.gz"

  if [ "$?" -eq 0 ]; then
    update_step_progress "ea-extract" "complete"
  else
    update_step_progress "ea-extract" "danger" "Failed to extract Elastic Agent, see script output for error."
    fail "Failed to extract Elastic Agent"
  fi
}

install_elastic_agent() {
  "./${elastic_agent_artifact_name}/elastic-agent" install -f

  if [ "$?" -eq 0 ]; then
    update_step_progress "ea-install" "complete"
  else
    update_step_progress "ea-install" "danger" "Failed to install Elastic Agent, see script output for error."
    fail "Failed to install Elastic Agent"
  fi
}

wait_for_elastic_agent_status() {
  local MAX_RETRIES=10
  local i=0
  echo -n "."
  elastic-agent status > /dev/null 2>&1
  local ELASTIC_AGENT_STATUS_EXIT_CODE="$?"
  while [ "$ELASTIC_AGENT_STATUS_EXIT_CODE" -ne 0 ] && [ $i -le $MAX_RETRIES ]; do
    sleep 1
    echo -n "."
    elastic-agent status > /dev/null 2>&1
    ELASTIC_AGENT_STATUS_EXIT_CODE="$?"
    ((i++))
  done
  echo ""

  if [ "$ELASTIC_AGENT_STATUS_EXIT_CODE" -ne 0 ]; then
    update_step_progress "ea-status" "warning" "Unable to determine agent status"
  fi
}

ensure_elastic_agent_healthy() {
  # https://www.elastic.co/guide/en/fleet/current/elastic-agent-cmd-options.html#elastic-agent-status-command
  ELASTIC_AGENT_STATES=(STARTING CONFIGURING HEALTHY DEGRADED FAILED STOPPING UPGRADING ROLLBACK)
  # Get elastic-agent status in json format | removing extra states in the json | finding "state":value | removing , | removing "state": | trimming the result
  ELASTIC_AGENT_STATE="$(elastic-agent status --output json | sed -n '/components/q;p' | grep state | sed 's/\(.*\),/\1 /' | sed 's/"state": //' | sed 's/[[:space:]]//g')"
  # Get elastic-agent status in json format | removing extra states in the json | finding "message":value | removing , | removing "message": | trimming the result | removing ""
  ELASTIC_AGENT_MESSAGE="$(elastic-agent status --output json | sed -n '/components/q;p' | grep message | sed 's/\(.*\),/\1 /' | sed 's/"message": //' | sed 's/[[:space:]]//g' | sed 's/\"//g')"
  # Get elastic-agent status in json format | removing extra ids in the json | finding "id":value | removing , | removing "id": | trimming the result | removing ""
  ELASTIC_AGENT_ID="$(elastic-agent status --output json | sed -n '/components/q;p' | grep \"id\" | sed 's/\(.*\),/\1 /' | sed 's/"id": //' | sed 's/[[:space:]]//g' | sed 's/\"//g')"

  if [ "${ELASTIC_AGENT_STATE}" = "2" ] && [ "${ELASTIC_AGENT_MESSAGE}" = "Running" ]; then
    update_step_progress "ea-status" "complete" "" "{\"agentId\": \"${ELASTIC_AGENT_ID}\"}"
  else
    update_step_progress "ea-status" "danger" "Expected agent status HEALTHY / Running but got ${ELASTIC_AGENT_STATES[ELASTIC_AGENT_STATE]} / ${ELASTIC_AGENT_MESSAGE}"
    fail "Elastic Agent is not healthy.\nCurrent status: ${ELASTIC_AGENT_STATES[ELASTIC_AGENT_STATE]} / ${ELASTIC_AGENT_MESSAGE}.\nFor help, please see our troubleshooting guide at https://www.elastic.co/guide/en/fleet/8.13/fleet-troubleshooting.html."
  fi
}

download_elastic_agent_config() {
  local decoded_ingest_api_key=$(echo "$ingest_api_key_encoded" | base64 -d)
  local tmp_path="/tmp/elastic-agent-config-template.yml"

  update_step_progress "ea-config" "loading"

  curl --request POST \
    -o $tmp_path \
    --url "$kibana_api_endpoint/internal/observability_onboarding/flow/$onboarding_flow_id/integrations/install" \
    --header "Authorization: ApiKey $install_api_key_encoded" \
    --header "Content-Type: text/tab-separated-values" \
    --data "$(echo -e "$install_integrations_api_body_string")" \
    --no-progress-meter

  if [ "$?" -ne 0 ]; then
    update_step_progress "ea-config" "warning" "Failed to install integrations and download Elastic Agent config."
    fail "Failed to install integrations and download Elastic Agent config."
  fi

  sed "s/'\${API_KEY}'/$decoded_ingest_api_key/g" $tmp_path > $elastic_agent_config_path
}

read_open_log_file_list() {
  local exclude_patterns=(
    "^\/Users\/.+?\/Library\/Application Support"
    "^\/Users\/.+?\/Library\/Caches"
    "^\/private"
    # Excluding all patterns that correspond to known integrations
    # that we are detecting separately
    "^\/var\/log\/nginx"
    "^\/var\/log\/apache2"
    "^\/var\/log\/httpd"
    "^\/var\/lib\/docker\/containers"
    "^\/var\/log\/syslog"
    "^\/var\/log\/auth.log"
    "^\/var\/log\/system.log"
    "^\/var\/log\/messages"
    "^\/var\/log\/secure"
  )

  local list=$(lsof -Fn | grep "\.log$" | awk '/^n/ {print substr($0, 2)}' | sort | uniq)

  # Filtering by the exclude patterns
  while IFS= read -r line; do
      if ! grep -qE "$(IFS="|"; echo "${exclude_patterns[*]}")" <<< "$line"; then
          unknown_log_file_path_list_string+="$line\n"
      fi
  done <<< "$list"
}

detect_known_integrations() {
  local nginx_patterns=(
    "/var/log/nginx/access.log*"
    "/var/log/nginx/error.log*"
  )

  for pattern in "${nginx_patterns[@]}"; do
    if compgen -G "$pattern" > /dev/null; then
      known_integrations_list_string+="nginx"$'\n'
      break
    fi
  done

  local apache_patterns=(
    "/var/log/apache2/access.log*"
    "/var/log/apache2/other_vhosts_access.log*"
    "/var/log/apache2/error.log*"
    "/var/log/httpd/access_log*"
    "/var/log/httpd/error_log*"
  )

  for pattern in "${apache_patterns[@]}"; do
    if compgen -G "$pattern" > /dev/null; then
      known_integrations_list_string+="apache"$'\n'
      break
    fi
  done

  if compgen -G "/var/lib/docker/containers/*/*-json.log" > /dev/null; then
    known_integrations_list_string+="docker"$'\n'
  fi

  local system_patterns=(
    "/var/log/messages*"
    "/var/log/syslog*"
    "/var/log/system*"
    "/var/log/auth.log*"
    "/var/log/secure*"
    "/var/log/system.log*"
  )

  for pattern in "${system_patterns[@]}"; do
    if compgen -G "$pattern" > /dev/null; then
      known_integrations_list_string+="system"$'\n'
      break
    fi
  done
}

known_integration_title() {
  local integration=$1
  case $integration in
    "nginx")
      echo "Nginx Logs"
      ;;
    "apache")
      echo "Apache Logs"
      ;;
    "docker")
      echo "Docker Container Logs"
      ;;
    "system")
      echo "System Logs"
      ;;
    *)
      echo "Unknown"
      ;;
  esac
}

build_unknown_log_file_patterns() {
  while IFS= read -r log_file_path; do
    unknown_log_file_pattern_list_string+="$(dirname "$log_file_path")/*.log\n"
  done <<< "$(echo -e $unknown_log_file_path_list_string)"

  unknown_log_file_pattern_list_string=$(echo -e "$unknown_log_file_pattern_list_string" | sort -u)
}

function select_list() {
  local known_integrations_options=()
  local unknown_logs_options=()

  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      continue
    fi
    known_integrations_options+=("$line")
  done <<< "$known_integrations_list_string"

  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      continue
    fi
    unknown_logs_options+=("$line")
  done <<< "$unknown_log_file_pattern_list_string"

  local options=("${known_integrations_options[@]}" "${unknown_logs_options[@]}")

  for i in "${!options[@]}"; do
    if [[ "$i" -lt "${#known_integrations_options[@]}" ]]; then
      printf "\e[32m%s)\e[0m %s\n" "$((i + 1))" "$(known_integration_title "${options[$i]}")"
    else
      printf "\e[32m%s)\e[0m %s\n" "$((i + 1))" "${options[$i]}"
    fi
  done

  echo -e "\n"
  read -p "Do you want to ingest all of these logs? [Y/n] (default: Yes): " confirmation_reply
  confirmation_reply="${confirmation_reply:-Y}"

  if [[ ! "$confirmation_reply" =~ ^[Yy](es)?$ ]]; then
    echo -e "\nExclude logs by listing their index numbers (e.g. 1, 2, 3):"
    read exclude_index_list_string

    IFS=', ' read -r -a exclude_index_list_array <<< "$exclude_index_list_string"

    for index in "${!options[@]}"; do
      local is_excluded=0
      for excluded_index in "${exclude_index_list_array[@]}"; do
        if [[ "$index" -eq "$((excluded_index - 1))" ]]; then
            is_excluded=1
        fi
      done

      if [[ $is_excluded -eq 0 ]]; then
        if [[ "$index" -lt "${#known_integrations_options[@]}" ]]; then
          selected_known_integrations_array+=("${options[index]}")
        else
          selected_unknown_log_file_pattern_array+=("${options[index]}")
        fi
      else
        if [[ "$index" -lt "${#known_integrations_options[@]}" ]]; then
          excluded_options_string+="$((index + 1))) $(known_integration_title "${options[index]}")\n"
        else
          excluded_options_string+="$((index + 1))) ${options[index]}\n"
        fi
      fi
    done
  else
    selected_known_integrations_array=("${known_integrations_options[@]}")
    selected_unknown_log_file_pattern_array=("${unknown_logs_options[@]}")
  fi
}

generate_custom_integration_name() {
    local path_pattern="$1"
    local dir_path
    local name_parts=()
    local name

    dir_path=$(dirname "$path_pattern")
    IFS='/' read -r -a dir_array <<< "$dir_path"

    # Get the last up to 4 parts of the path
    for (( i=${#dir_array[@]}-1, count=0; i>=0 && count<4; i--, count++ )); do
        name_parts=("${dir_array[$i]}" "${name_parts[@]}")
    done

    # Join the parts into a single string with underscores
    name=$(printf "%s_" "${name_parts[@]}")
    name="${name#_}"  # Remove leading underscore
    name="${name%_}"  # Remove trailing underscore

    # Replace special characters with underscores
    name="${name// /_}"
    name="${name//-/_}"
    name="${name//./_}"

    echo "$name"
}

build_install_integrations_api_body_string() {
  for item in "${selected_known_integrations_array[@]}"; do
    install_integrations_api_body_string+="$item\tregistry\n"
  done

  for item in "${selected_unknown_log_file_pattern_array[@]}" "${custom_log_file_path_list_array[@]}"; do
    local integration_name=$(generate_custom_integration_name "$item")

    install_integrations_api_body_string+="$integration_name\tcustom\t$item\n"
  done
}

echo "Looking for log files..."
detect_known_integrations
read_open_log_file_list
build_unknown_log_file_patterns

echo -e "\nWe found these logs on your system:"
select_list

if [[ -n "$excluded_options_string" ]]; then
  echo -e "\nThese logs will not be ingested:"
  echo -e "$excluded_options_string"
fi

echo -e "\nAdd paths to any custom logs we've missed (e.g. /var/log/myapp/*.log, /home/j/myapp/*.log). Press Enter to skip."
read custom_log_file_path_list_string

IFS=', ' read -r -a custom_log_file_path_list_array <<< "$custom_log_file_path_list_string"

echo -e "\nYou've selected these logs to ingest:"
for item in "${selected_known_integrations_array[@]}"; do
  printf "• %s\n" "$(known_integration_title "${item}")"
done
for item in "${selected_unknown_log_file_pattern_array[@]}" "${custom_log_file_path_list_array[@]}"; do
  printf "• %s\n" "$item"
done

echo -e "\n"
read -p "Confirm selection [Y/n] (default: Yes): " confirmation_reply
confirmation_reply="${confirmation_reply:-Y}"

if [[ ! "$confirmation_reply" =~ ^[Yy](es)?$ ]]; then
  echo -e "Rerun the script again to select different logs."
  exit 1
fi

build_install_integrations_api_body_string

echo -e "\nDownloading Elastic Agent..."
download_elastic_agent
extract_elastic_agent

echo -e "\nInstalling Elastic Agent..."
install_elastic_agent
wait_for_elastic_agent_status
ensure_elastic_agent_healthy

echo -e "\nDownloading Elastic Agent configuration..."
download_elastic_agent_config

update_step_progress "ea-config" "complete"
printf "\n\e[32m%s\e[0m\n" "🎉 Elastic Agent is configured and running. You can now go back to Kibana and check for incoming logs."
