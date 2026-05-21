#!/usr/bin/env bash
set -euo pipefail

# Reads Terraform outputs and deploys the FastAPI app to Azure App Service.
# Run from the repo root: ./deploy.sh
# Prerequisites: terraform applied, az CLI logged in, zip installed.

TF_DIR="$(dirname "$0")/terraform"

APP_NAME=$(terraform -chdir="$TF_DIR" output -raw app_service_name)
RG=$(terraform -chdir="$TF_DIR" output -raw resource_group_name)

echo "Deploying to: $APP_NAME ($RG)"

cd "$(dirname "$0")/app"

zip -r ../deploy.zip . \
  --exclude "*.pyc" \
  --exclude "*/__pycache__/*" \
  --exclude "*/.env"

cd ..

az webapp deploy \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --src-path deploy.zip \
  --type zip \
  --async true

rm deploy.zip

echo ""
echo "Done. App URL:"
terraform -chdir="$TF_DIR" output -raw app_url
echo ""
