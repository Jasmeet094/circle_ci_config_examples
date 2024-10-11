SHELL = /bin/bash -o pipefail

.PHONY: docker-repo-login Notification-AWS-docker-build update-lambda Api-Notification-docker-build Api-Notification-deploy-service

DOCKER := docker
COMMIT_ID := $(shell git rev-parse --short HEAD)

set_up_key:
	ssh-add -D
	ssh-add ~/.ssh/id_rsa_e5b4ea423df715847665c458e4e53402

# ECR repo login command
docker-repo-login:
	eval $$\( aws ecr get-login --no-include-email --region ${REGION}\)


# ECS DOCKER BUILD PUSH AND ECS DEPLOY CODE BELOW:

# ECS Service named finexio-ng-notifications-api-finexio-environment docker commands and ECS Deploy
Api-Notification-docker-build: docker-repo-login set_up_key
	docker build -f ${Dockerfile_Path} -t finexio-ng-notifications-api .
	docker tag finexio-ng-notifications-api:latest ${AWS_ECR_ACCOUNT_URL}/finexio-ng-notifications-api:${COMMIT_ID}
	docker tag finexio-ng-notifications-api:latest ${AWS_ECR_ACCOUNT_URL}/finexio-ng-notifications-api:latest
	docker push ${AWS_ECR_ACCOUNT_URL}/finexio-ng-notifications-api:${COMMIT_ID}
	docker push ${AWS_ECR_ACCOUNT_URL}/finexio-ng-notifications-api:latest

Api-Notification-deploy-service:
	ecs deploy --region ${REGION} ${NG_CLUSTER} ${NG_FINEXIO_NOTIFICATION_API_SERVICE} --image ${NG_FINEXIO_NOTIFICATION_API_CONTAINER} ${AWS_ECR_ACCOUNT_URL}/finexio-ng-notifications-api:${COMMIT_ID} --timeout 1800 --no-deregister --rollback

Api-Notification-update-commit-id-ssm-parameter:
	aws ssm put-parameter --overwrite --name "finexio-ng-notifications-commit-id" --type "String" --value ${COMMIT_ID} --region ${REGION}

# Project Finexio.Services.Api docker build and push plus ECS Deploy
Services-AWS-docker-build-test:
	docker build -f ${Dockerfile_Path} -t finexio-services-aws-test .
	docker run --name finexio-services-aws-test finexio-services-aws-test

Services-Api-docdb-queries-docker-build: docker-repo-login set_up_key
	docker build -f ${Dockerfile_Path} -t finexio-ng-services-api .
	docker tag finexio-ng-services-api:latest ${AWS_ECR_ACCOUNT_URL}/finexio-ng-services-api:documentdb-queries-${COMMIT_ID}
	docker tag finexio-ng-services-api:latest ${AWS_ECR_ACCOUNT_URL}/finexio-ng-services-api:documentdb-queries-latest
	docker push ${AWS_ECR_ACCOUNT_URL}/finexio-ng-services-api:documentdb-queries-${COMMIT_ID}
	docker push ${AWS_ECR_ACCOUNT_URL}/finexio-ng-services-api:documentdb-queries-latest

Services-Api-docdb-queries-collection: Services-Api-docdb-queries-docker-build # Stand along task to execute documentdb script
	$(eval TASK_DEFINITION=$(shell ecs update --image ${NG_FINEXIO_SERVICE_API_CONTAINER} ${AWS_ECR_ACCOUNT_URL}/finexio-ng-services-api:documentdb-queries-${COMMIT_ID} \
	${SERVICES_API_TASK_DEFINTION_REVISION} --no-deregister --region ${REGION} ))

	# Small delay so that New Container use correct & Latest Task Defintion
	sleep 10

	# Step 2: Capture the newly created task definition revision
	$(eval NEW_TASK_DEF_REVISION=$(shell aws ecs describe-task-definition --task-definition ${SERVICES_API_TASK_DEFINTION_REVISION} --region ${REGION} | jq -r '.taskDefinition.revision'))

	@echo "New Task Definition Revision: ${NEW_TASK_DEF_REVISION}"

	# Run the ECS task and capture the task ARN
	$(eval TASK_ARN=$(shell aws ecs run-task --cluster ${NG_CLUSTER} \
		--task-definition ${SERVICES_API_TASK_DEFINTION_REVISION}:${NEW_TASK_DEF_REVISION} \
		--network-configuration "awsvpcConfiguration={subnets=${NG_SERVICES_API_SUBNETS},securityGroups=${NG_SERVICE_API_SG}}" \
		--launch-type FARGATE \
		--overrides '{ "containerOverrides": [ { "name": "${NG_FINEXIO_SERVICE_API_CONTAINER}", "command": ["/bin/bash","-c","chmod +x /app/doc_collection.sh && /app/doc_collection.sh ${FINEXIO_DOCUMENT_DB_SECRET}"] } ] }' \
		--region ${REGION} | jq -r '.tasks[0].taskArn'))

	@echo "Task ARN: ${TASK_ARN}"

	# Wait for the ECS task to complete
	$(eval WAIT_FOR_TASK=$(shell aws ecs wait tasks-stopped --cluster ${NG_CLUSTER} --tasks ${TASK_ARN} --region ${REGION}))

	# Introduce a small delay (if needed)
	sleep 10

	# Get the exit code of the main container using a partial match on the container name
	$(eval TASK_EXIT_CODE=$(shell aws ecs describe-tasks --cluster ${NG_CLUSTER} --region ${REGION} --tasks ${TASK_ARN} | jq -r '.tasks[0].containers[] | select(.name | contains("container-finexio-ng-services-api")) | .exitCode'))

	@echo "Task ARN: ${TASK_ARN}"
	@echo "Task Exit Code for Main Container: ${TASK_EXIT_CODE}"

	# Add a new step to print the main container name
	$(eval MAIN_CONTAINER_NAME=$(shell aws ecs describe-tasks --cluster ${NG_CLUSTER} --region ${REGION} --tasks ${TASK_ARN} | jq -r '.tasks[0].containers[] | select(.name | contains("container-finexio-ng-services-api")) | .name'))

	@echo "Main Container Name: ${MAIN_CONTAINER_NAME}"

	# Check the exit code of the main container and handle success or failure
	if [ "${TASK_EXIT_CODE}" -eq 0 ]; then \
		echo "Main container in ECS task ${TASK_ARN} completed successfully."; \
	else \
		echo "Main container in ECS task ${TASK_ARN} failed with exit code ${TASK_EXIT_CODE}."; \
		exit 1; \
	fi

aws-assume:
	$(eval OUTPUT=$(shell aws sts assume-role-with-web-identity --role-arn ${AWS_ROLE_ARN} --role-session-name ${CIRCLE_WORKFLOW_ID} --web-identity-token ${CIRCLE_OIDC_TOKEN} --duration-seconds 3600 --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) )
	$(eval AWS_ACCESS_KEY_ID=$(shell echo $(OUTPUT) | cut -d " " -f1 ) )
	$(eval AWS_SECRET_ACCESS_KEY=$(shell echo $(OUTPUT) | cut -d " " -f2 ) )
	$(eval AWS_SESSION_TOKEN=$(shell echo $(OUTPUT) | cut -d " " -f3 ) )

	$(eval CONFIGURE=$(shell aws configure set aws_access_key_id $(AWS_ACCESS_KEY_ID) && aws configure set aws_secret_access_key $(AWS_SECRET_ACCESS_KEY) && aws configure set aws_session_token $(AWS_SESSION_TOKEN) ))

Sonar-Scanner-Analysis:
	dotnet tool restore
	dotnet sonarscanner begin /k:"finexioinc_fx-ng" /d:sonar.token="${SonarToken}" /d:sonar.host.url="https://sonarcloud.io" /o:"finexio" \
		/d:sonar.qualitygate.wait=true /d:sonar.pullrequest.provider="Github" /d:sonar.pullrequest.github.repository="${Repository}" \
		/d:sonar.pullrequest.branch="${Branch_Name}" /d:sonar.pullrequest.base="${Target_Branch_Name}" /d:sonar.pullrequest.key=${PR_Key} \
		/d:sonar.cs.vscoveragexml.reportsPaths=coverage.xml \
		/d:sonar.exclusions="**/Contracts/**/*.*, **/Enums/**/*.*, **/Exceptions/**/*.*, **/Models/**/*.*, **/DTO/**/*.*, **/Extensions/**/*.*, **/Interfaces/**/*.*, **/wwwroot/**/*.*, **/*.html, **/*.css"
	dotnet build ${Solution_File_Path} --no-incremental
	dotnet coverage collect "dotnet test ${Solution_File_Path} --no-build" -f xml -o "coverage.xml"
	dotnet sonarscanner end /d:sonar.token="${SonarToken}"

Sonar-Scanner-Analysis-Develop:
	dotnet tool restore
	dotnet sonarscanner begin /k:"finexioinc_fx-ng" /d:sonar.token="${SonarToken}" /d:sonar.host.url="https://sonarcloud.io" /o:"finexio" \
		/d:sonar.branch.name="develop" /d:sonar.cs.vscoveragexml.reportsPaths=coverage.xml \
		/d:sonar.exclusions="**/Contracts/**/*.*, **/Enums/**/*.*, **/Exceptions/**/*.*, **/Models/**/*.*, **/DTO/**/*.*, **/Extensions/**/*.*, **/Interfaces/**/*.*, **/wwwroot/**/*.*, **/*.html, **/*.css"
	dotnet build ${Solution_File_Path} --no-incremental
	dotnet coverage collect "dotnet test ${Solution_File_Path} --no-build" -f xml -o "coverage.xml"
	dotnet sonarscanner end /d:sonar.token="${SonarToken}"
