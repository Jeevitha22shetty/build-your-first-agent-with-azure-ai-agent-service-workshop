#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

echo "Deploying the Azure resources..."

# Define resource group parameters
RG_LOCATION="westus"
MODEL_NAME="gpt-4o-mini"
MODEL_VERSION="2024-07-18"
AI_PROJECT_FRIENDLY_NAME="Contoso Agent Service Workshop"
MODEL_CAPACITY=10

# Allow overriding the unique suffix via env var or first arg
# Generate a longer suffix by default to reduce name collisions
if [ "${1:-}" != "" ]; then
  case "$1" in
    --suffix=*) UNIQUE_SUFFIX="${1#--suffix=}" ;;
    *) ;;
  esac
fi
UNIQUE_SUFFIX="${UNIQUE_SUFFIX:-}"
if [ -z "$UNIQUE_SUFFIX" ]; then
  # Generate a 4-character hex suffix by default to match the Bicep parameter constraint
  if command -v openssl >/dev/null 2>&1; then
    UNIQUE_SUFFIX=$(openssl rand -hex 2)
  elif command -v uuidgen >/dev/null 2>&1; then
    UNIQUE_SUFFIX=$(uuidgen | tr -d '-' | cut -c1-4)
  elif command -v sha1sum >/dev/null 2>&1; then
    UNIQUE_SUFFIX=$(date +%s%N | sha1sum | cut -c1-4)
  else
    # Fallback to a timestamp-based suffix (digits) trimmed to 4 chars
    UNIQUE_SUFFIX=$(date +%s%N | sed -E 's/[^0-9]//g' | tail -c 4)
  fi
fi
DEPLOYMENT_NAME="azure-ai-agent-service-lab-${UNIQUE_SUFFIX}"

# Print the resource group name that will be created
RESOURCE_GROUP_NAME="rg-contoso-agent-workshop-${UNIQUE_SUFFIX}"
echo "Resource group that will be created: $RESOURCE_GROUP_NAME"

die() {
  echo "ERROR: $1" >&2
  exit ${2:-1}
}

# Ensure required commands are available
for cmd in az jq dotnet; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "$cmd is required but not installed or not on PATH"
  fi
done

# Use a temporary file for the deployment output and ensure cleanup
OUTPUT_JSON=$(mktemp --suffix=._azure_deploy.json)
trap 'rm -f "$OUTPUT_JSON"' EXIT

# Deploy the Azure resources and save output to JSON
echo "Running Azure deployment (this may take several minutes)..."
az deployment sub create \
  --name "$DEPLOYMENT_NAME" \
  --location "$RG_LOCATION" \
  --template-file main.bicep \
  --parameters \
      uniqueSuffix="$UNIQUE_SUFFIX" \
      resourcePrefix="contoso-agent-workshop" \
      location="$RG_LOCATION" \
      aiProjectFriendlyName="$AI_PROJECT_FRIENDLY_NAME" \
      modelName="$MODEL_NAME" \
      modelCapacity="$MODEL_CAPACITY" \
      modelVersion="$MODEL_VERSION" > "$OUTPUT_JSON"

if [ ! -s "$OUTPUT_JSON" ]; then
  die "Deployment did not produce output or failed"
fi

PROJECTS_ENDPOINT=$(jq -r '.properties.outputs.projectsEndpoint.value // empty' "$OUTPUT_JSON")
RESOURCE_GROUP_NAME=$(jq -r '.properties.outputs.resourceGroupName.value // empty' "$OUTPUT_JSON")
SUBSCRIPTION_ID=$(jq -r '.properties.outputs.subscriptionId.value // empty' "$OUTPUT_JSON")
AI_SERVICE_NAME=$(jq -r '.properties.outputs.aiAccountName.value // empty' "$OUTPUT_JSON")
AI_PROJECT_NAME=$(jq -r '.properties.outputs.aiProjectName.value // empty' "$OUTPUT_JSON")

if [ -z "$PROJECTS_ENDPOINT" ]; then
  die "projectsEndpoint not found in deployment output. Possible deployment failure."
fi

ENV_FILE_PATH="../src/python/workshop/.env"

# Ensure destination directory exists
mkdir -p "$(dirname "$ENV_FILE_PATH")"

# Write to the .env file (overwrite)
{
  echo "PROJECT_ENDPOINT=$PROJECTS_ENDPOINT"
  echo "MODEL_DEPLOYMENT_NAME=$MODEL_NAME"
} > "$ENV_FILE_PATH"

CSHARP_PROJECT_PATH="../src/csharp/workshop/AgentWorkshop.Client/AgentWorkshop.Client.csproj"

# Set the user secrets for the C# project (best-effort)
if command -v dotnet >/dev/null 2>&1; then
  echo "Updating C# user-secrets..."
  if ! dotnet user-secrets set "ConnectionStrings:AiAgentService" "$PROJECTS_ENDPOINT" --project "$CSHARP_PROJECT_PATH"; then
    echo "Warning: failed to set ConnectionStrings:AiAgentService user-secret (continuing)" >&2
  fi
  if ! dotnet user-secrets set "Azure:ModelName" "$MODEL_NAME" --project "$CSHARP_PROJECT_PATH"; then
    echo "Warning: failed to set Azure:ModelName user-secret (continuing)" >&2
  fi
fi

echo "Adding Azure AI Developer user role"

# Set Variables
subId=$(az account show --query id --output tsv || true)
if [ -z "$subId" ]; then
  die "Unable to determine subscription id. Are you logged into Azure CLI?"
fi

# Get the current signed-in user's object id
objectId=$(az ad signed-in-user show --query id -o tsv || true)
if [ -z "$objectId" ]; then
  die "Unable to determine signed-in user object id. Ensure Azure CLI has permission to read user info."
fi

SCOPE="/subscriptions/$subId/resourceGroups/$RESOURCE_GROUP_NAME"

if az role assignment create --role "Azure AI Developer" --assignee "$objectId" --scope "$SCOPE"; then
  echo "User role assignment succeeded."
else
  die "User role assignment failed."
fi