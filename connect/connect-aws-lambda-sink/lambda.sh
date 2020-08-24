#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

${DIR}/../../environment/plaintext/start.sh "${PWD}/docker-compose.plaintext.yml"

log "Sending messages to topic add-topic"
seq -f "{\"a\": %g,\"b\": 1}" 10 | docker exec -i connect kafka-avro-console-producer --broker-list broker:9092 --property schema.registry.url=http://schema-registry:8081 --topic add-topic --property value.schema='{"type":"record","name":"myrecord","fields":[{"name":"a","type":"int"},{"name":"b","type":"int"}]}'

log "Creating AWS Lambda Sink connector"
docker exec connect \
     curl -X PUT \
     -H "Content-Type: application/json" \
     --data '{
               "connector.class" : "io.confluent.connect.aws.lambda.AwsLambdaSinkConnector",
                    "tasks.max": "1",
                    "topics" : "add-topic",
                    "aws.lambda.function.name" : "Add",
                    "aws.lambda.invocation.type" : "sync",
                    "aws.lambda.batch.size" : "50",
                    "behavior.on.error" : "fail",
                    "aws.lambda.response.topic": "add-topic-response",
                    "aws.lambda.response.bootstrap.servers": "broker:9092",
                    "aws.lambda.response.client.id": "add-topic-response-client",
                    "reporter.bootstrap.servers": "broker:9092",
                    "reporter.error.topic.name": "error-responses",
                    "reporter.error.topic.replication.factor": 1,
                    "reporter.result.topic.name": "success-responses",
                    "reporter.result.topic.replication.factor": 1,
                    "confluent.license": "",
                    "confluent.topic.bootstrap.servers": "broker:9092",
                    "confluent.topic.replication.factor": "1"
          }' \
     http://localhost:8083/connectors/aws-lambda/config | jq .


sleep 20

set +e
log "Verifying topic add-topic-response"
timeout 60 docker exec broker kafka-console-consumer -bootstrap-server broker:9092 --topic add-topic-response --from-beginning --max-messages 10

log "Verify topic success-responses"
timeout 60 docker exec broker kafka-console-consumer -bootstrap-server broker:9092 --topic success-responses --from-beginning --max-messages 1

log "Verify topic error-responses"
timeout 20 docker exec broker kafka-console-consumer -bootstrap-server broker:9092 --topic error-responses --from-beginning --max-messages 1