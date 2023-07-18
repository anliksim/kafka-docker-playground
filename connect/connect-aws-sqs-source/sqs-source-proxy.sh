#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -f $HOME/.aws/credentials ] && ( [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] )
then
     logerror "ERROR: either the file $HOME/.aws/credentials is not present or environment variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are not set!"
     exit 1
else
    if [ ! -z "$AWS_ACCESS_KEY_ID" ] && [ ! -z "$AWS_SECRET_ACCESS_KEY" ]
    then
        log "💭 Using environment variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
    else
        if [ -f $HOME/.aws/credentials ]
        then
            logwarn "💭 AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are set based on $HOME/.aws/credentials"
            export AWS_ACCESS_KEY_ID=$( grep "^aws_access_key_id" $HOME/.aws/credentials| awk -F'=' '{print $2;}' )
            export AWS_SECRET_ACCESS_KEY=$( grep "^aws_secret_access_key" $HOME/.aws/credentials| awk -F'=' '{print $2;}' ) 
        fi
    fi
    if [ -z "$AWS_REGION" ]
    then
        AWS_REGION=$(aws configure get region | tr '\r' '\n')
        if [ "$AWS_REGION" == "" ]
        then
            logerror "ERROR: either the file $HOME/.aws/config is not present or environment variables AWS_REGION is not set!"
            exit 1
        fi
    fi
fi

if [[ "$TAG" == *ubi8 ]] || version_gt $TAG_BASE "5.9.0"
then
     export CONNECT_CONTAINER_HOME_DIR="/home/appuser"
else
     export CONNECT_CONTAINER_HOME_DIR="/root"
fi

${DIR}/../../environment/plaintext/start.sh "${PWD}/docker-compose.plaintext.proxy.yml"

QUEUE_NAME=pg${USER}sqs${TAG}
QUEUE_NAME=${QUEUE_NAME//[-._]/}

QUEUE_URL_RAW=$(aws sqs create-queue --queue-name $QUEUE_NAME | jq .QueueUrl)
AWS_ACCOUNT_NUMBER=$(echo "$QUEUE_URL_RAW" | cut -d "/" -f 4)
# https://docs.amazonaws.cn/sdk-for-net/v3/developer-guide/how-to/sqs/QueueURL.html
# https://{REGION_ENDPOINT}/queue.|api-domain|/{YOUR_ACCOUNT_NUMBER}/{YOUR_QUEUE_NAME}
QUEUE_URL="https://sqs.$AWS_REGION.amazonaws.com/$AWS_ACCOUNT_NUMBER/$QUEUE_NAME"

set +e
log "Delete queue ${QUEUE_URL}"
aws sqs delete-queue --queue-url ${QUEUE_URL}
if [ $? -eq 0 ]
then
     # You must wait 60 seconds after deleting a queue before you can create another with the same name
     log "Sleeping 60 seconds"
     sleep 60
fi
set -e

log "Create a FIFO queue $QUEUE_NAME"
aws sqs create-queue --queue-name $QUEUE_NAME

log "Sending messages to $QUEUE_URL"
cd ../../connect/connect-aws-sqs-source
aws sqs send-message-batch --queue-url $QUEUE_URL --entries file://send-message-batch.json
cd -

log "Creating SQS Source connector"
playground connector create-or-update --connector sqs-source << EOF
{
    "connector.class": "io.confluent.connect.sqs.source.SqsSourceConnector",
    "tasks.max": "1",
    "kafka.topic": "test-sqs-source",
    "sqs.url": "$QUEUE_URL",
    "aws.access.key.id" : "$AWS_ACCESS_KEY_ID",
    "aws.secret.key.id": "$AWS_SECRET_ACCESS_KEY",
    "confluent.license": "",
    "sqs.proxy.url": "https://nginx-proxy:8888",
    "confluent.topic.bootstrap.servers": "broker:9092",
    "confluent.topic.replication.factor": "1",
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
}
EOF

# [2023-07-15 14:24:24,944] ERROR Could not connect to your Amazon SQS queue (io.confluent.connect.sqs.source.SqsSourceConfigValidation:174)
# software.amazon.awssdk.core.exception.SdkClientException: Unable to execute HTTP request: Unable to send CONNECT request to proxy
#         at software.amazon.awssdk.core.exception.SdkClientException$BuilderImpl.build(SdkClientException.java:111)
#         at software.amazon.awssdk.core.exception.SdkClientException.create(SdkClientException.java:47)
#         at software.amazon.awssdk.core.internal.http.pipeline.stages.utils.RetryableStageHelper.setLastException(RetryableStageHelper.java:223)
#         at software.amazon.awssdk.core.internal.http.pipeline.stages.utils.RetryableStageHelper.setLastException(RetryableStageHelper.java:218)
#         at software.amazon.awssdk.core.internal.http.pipeline.stages.AsyncRetryableStage$RetryingExecutor.maybeRetryExecute(AsyncRetryableStage.java:182)
#         at software.amazon.awssdk.core.internal.http.pipeline.stages.AsyncRetryableStage$RetryingExecutor.lambda$attemptExecute$1(AsyncRetryableStage.java:159)
#         at java.base/java.util.concurrent.CompletableFuture.uniWhenComplete(CompletableFuture.java:859)
#         at java.base/java.util.concurrent.CompletableFuture$UniWhenComplete.tryFire(CompletableFuture.java:837)
#         at java.base/java.util.concurrent.CompletableFuture.postComplete(CompletableFuture.java:506)
#         at java.base/java.util.concurrent.CompletableFuture.completeExceptionally(CompletableFuture.java:2088)
#         at software.amazon.awssdk.utils.CompletableFutureUtils.lambda$forwardExceptionTo$0(CompletableFutureUtils.java:79)
#         at java.base/java.util.concurrent.CompletableFuture.uniWhenComplete(CompletableFuture.java:859)
#         at java.base/java.util.concurrent.CompletableFuture$UniWhenComplete.tryFire(CompletableFuture.java:837)
#         at java.base/java.util.concurrent.CompletableFuture.postComplete(CompletableFuture.java:506)
#         at java.base/java.util.concurrent.CompletableFuture.completeExceptionally(CompletableFuture.java:2088)
#         at software.amazon.awssdk.core.internal.http.pipeline.stages.MakeAsyncHttpRequestStage.lambda$null$0(MakeAsyncHttpRequestStage.java:103)
#         at java.base/java.util.concurrent.CompletableFuture.uniWhenComplete(CompletableFuture.java:859)
#         at java.base/java.util.concurrent.CompletableFuture$UniWhenComplete.tryFire(CompletableFuture.java:837)
#         at java.base/java.util.concurrent.CompletableFuture.postComplete(CompletableFuture.java:506)
#         at java.base/java.util.concurrent.CompletableFuture.completeExceptionally(CompletableFuture.java:2088)
#         at software.amazon.awssdk.core.internal.http.pipeline.stages.MakeAsyncHttpRequestStage.completeResponseFuture(MakeAsyncHttpRequestStage.java:240)
#         at software.amazon.awssdk.core.internal.http.pipeline.stages.MakeAsyncHttpRequestStage.lambda$executeHttpRequest$3(MakeAsyncHttpRequestStage.java:163)
#         at java.base/java.util.concurrent.CompletableFuture.uniHandle(CompletableFuture.java:930)
#         at java.base/java.util.concurrent.CompletableFuture$UniHandle.tryFire(CompletableFuture.java:907)
#         at java.base/java.util.concurrent.CompletableFuture$Completion.run(CompletableFuture.java:478)
#         at java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1128)
#         at java.base/java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:628)
#         at java.base/java.lang.Thread.run(Thread.java:829)
#         Suppressed: software.amazon.awssdk.core.exception.SdkClientException: Request attempt 1 failure: Unable to execute HTTP request: Unable to send CONNECT request to proxy
#         Suppressed: software.amazon.awssdk.core.exception.SdkClientException: Request attempt 2 failure: Unable to execute HTTP request: Unable to send CONNECT request to proxy
#         Suppressed: software.amazon.awssdk.core.exception.SdkClientException: Request attempt 3 failure: Unable to execute HTTP request: Unable to send CONNECT request to proxy
# Caused by: java.io.IOException: Unable to send CONNECT request to proxy
#         at software.amazon.awssdk.http.nio.netty.internal.ProxyTunnelInitHandler.handleConnectRequestFailure(ProxyTunnelInitHandler.java:138)
#         at software.amazon.awssdk.http.nio.netty.internal.ProxyTunnelInitHandler.lambda$handlerAdded$0(ProxyTunnelInitHandler.java:83)
#         at io.netty.util.concurrent.DefaultPromise.notifyListener0(DefaultPromise.java:590)
#         at io.netty.util.concurrent.DefaultPromise.notifyListenersNow(DefaultPromise.java:557)
#         at io.netty.util.concurrent.DefaultPromise.notifyListeners(DefaultPromise.java:492)
#         at io.netty.util.concurrent.DefaultPromise.setValue0(DefaultPromise.java:636)
#         at io.netty.util.concurrent.DefaultPromise.setFailure0(DefaultPromise.java:629)
#         at io.netty.util.concurrent.DefaultPromise.tryFailure(DefaultPromise.java:118)
#         at io.netty.util.internal.PromiseNotificationUtil.tryFailure(PromiseNotificationUtil.java:64)
#         at io.netty.channel.DelegatingChannelPromiseNotifier.operationComplete(DelegatingChannelPromiseNotifier.java:57)
#         at io.netty.channel.DelegatingChannelPromiseNotifier.operationComplete(DelegatingChannelPromiseNotifier.java:31)
#         at io.netty.util.concurrent.DefaultPromise.notifyListener0(DefaultPromise.java:590)
#         at io.netty.util.concurrent.DefaultPromise.notifyListenersNow(DefaultPromise.java:557)
#         at io.netty.util.concurrent.DefaultPromise.notifyListeners(DefaultPromise.java:492)
#         at io.netty.util.concurrent.DefaultPromise.setValue0(DefaultPromise.java:636)
#         at io.netty.util.concurrent.DefaultPromise.setFailure0(DefaultPromise.java:629)
#         at io.netty.util.concurrent.DefaultPromise.tryFailure(DefaultPromise.java:118)
#         at io.netty.util.internal.PromiseNotificationUtil.tryFailure(PromiseNotificationUtil.java:64)
#         at io.netty.channel.DelegatingChannelPromiseNotifier.operationComplete(DelegatingChannelPromiseNotifier.java:57)
#         at io.netty.channel.DelegatingChannelPromiseNotifier.operationComplete(DelegatingChannelPromiseNotifier.java:31)
#         at io.netty.channel.AbstractCoalescingBufferQueue.releaseAndCompleteAll(AbstractCoalescingBufferQueue.java:350)
#         at io.netty.channel.AbstractCoalescingBufferQueue.releaseAndFailAll(AbstractCoalescingBufferQueue.java:208)
#         at io.netty.handler.ssl.SslHandler.releaseAndFailAll(SslHandler.java:1909)
#         at io.netty.handler.ssl.SslHandler.setHandshakeFailure(SslHandler.java:1888)
#         at io.netty.handler.ssl.SslHandler.setHandshakeFailure(SslHandler.java:1853)
#         at io.netty.handler.ssl.SslHandler.decodeJdkCompatible(SslHandler.java:1220)
#         at io.netty.handler.ssl.SslHandler.decode(SslHandler.java:1285)
#         at io.netty.handler.codec.ByteToMessageDecoder.decodeRemovalReentryProtection(ByteToMessageDecoder.java:529)
#         at io.netty.handler.codec.ByteToMessageDecoder.callDecode(ByteToMessageDecoder.java:468)
#         at io.netty.handler.codec.ByteToMessageDecoder.channelRead(ByteToMessageDecoder.java:290)
#         at io.netty.channel.AbstractChannelHandlerContext.invokeChannelRead(AbstractChannelHandlerContext.java:444)
#         at io.netty.channel.AbstractChannelHandlerContext.invokeChannelRead(AbstractChannelHandlerContext.java:420)
#         at io.netty.channel.AbstractChannelHandlerContext.fireChannelRead(AbstractChannelHandlerContext.java:412)
#         at io.netty.channel.DefaultChannelPipeline$HeadContext.channelRead(DefaultChannelPipeline.java:1410)
#         at io.netty.channel.AbstractChannelHandlerContext.invokeChannelRead(AbstractChannelHandlerContext.java:440)
#         at io.netty.channel.AbstractChannelHandlerContext.invokeChannelRead(AbstractChannelHandlerContext.java:420)
#         at io.netty.channel.DefaultChannelPipeline.fireChannelRead(DefaultChannelPipeline.java:919)
#         at io.netty.channel.nio.AbstractNioByteChannel$NioByteUnsafe.read(AbstractNioByteChannel.java:166)
#         at io.netty.channel.nio.NioEventLoop.processSelectedKey(NioEventLoop.java:788)
#         at io.netty.channel.nio.NioEventLoop.processSelectedKeysOptimized(NioEventLoop.java:724)
#         at io.netty.channel.nio.NioEventLoop.processSelectedKeys(NioEventLoop.java:650)
#         at io.netty.channel.nio.NioEventLoop.run(NioEventLoop.java:562)
#         at io.netty.util.concurrent.SingleThreadEventExecutor$4.run(SingleThreadEventExecutor.java:997)
#         at io.netty.util.internal.ThreadExecutorMap$2.run(ThreadExecutorMap.java:74)
#         ... 1 more
# Caused by: io.netty.handler.ssl.NotSslRecordException: not an SSL/TLS record: 485454502f312e31203430302042616420526571756573740d0a5365727665723a206e67696e782f312e31382e3020285562756e7475290d0a446174653a205361742c203135204a756c20323032332031343a32343a323420474d540d0a436f6e74656e742d547970653a20746578742f68746d6c0d0a436f6e74656e742d4c656e6774683a203136360d0a436f6e6e656374696f6e3a20636c6f73650d0a0d0a3c68746d6c3e0d0a3c686561643e3c7469746c653e3430302042616420526571756573743c2f7469746c653e3c2f686561643e0d0a3c626f64793e0d0a3c63656e7465723e3c68313e3430302042616420526571756573743c2f68313e3c2f63656e7465723e0d0a3c68723e3c63656e7465723e6e67696e782f312e31382e3020285562756e7475293c2f63656e7465723e0d0a3c2f626f64793e0d0a3c2f68746d6c3e0d0a
#         at io.netty.handler.ssl.SslHandler.decodeJdkCompatible(SslHandler.java:1215)
#         ... 19 more

log "Verify we have received the data in test-sqs-source topic"
playground topic consume --topic test-sqs-source --min-expected-messages 2 --timeout 60

log "Delete queue ${QUEUE_URL}"
aws sqs delete-queue --queue-url ${QUEUE_URL}
