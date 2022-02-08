#!/bin/bash
# Copyright 2022, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

REPO_VERSION=${NVIDIA_TRITON_SERVER_VERSION}
if [ "$#" -ge 1 ]; then
    REPO_VERSION=$1
fi
if [ -z "$REPO_VERSION" ]; then
    echo -e "Repository version must be specified"
    echo -e "\n***\n*** Test Failed\n***"
    exit 1
fi
if [ ! -z "$TEST_REPO_ARCH" ]; then
    REPO_VERSION=${REPO_VERSION}_${TEST_REPO_ARCH}
fi

export CUDA_VISIBLE_DEVICES=0

TEST_RESULT_FILE='test_results.txt'
CLIENT_LOG_BASE="./client"
INFER_TEST=infer_test.py
SERVER_TIMEOUT=240

EXPECTED_NUM_TESTS=${EXPECTED_NUM_TESTS:="42"}
TF_VERSION=${TF_VERSION:=1}


MODELDIR=${MODELDIR:=`pwd`/models}
DATADIR=${DATADIR:="/data/inferenceserver/${REPO_VERSION}"}
TRITON_DIR=${TRITON_DIR:="/opt/tritonserver"}
SERVER=${TRITON_DIR}/bin/tritonserver
BACKEND_DIR=${TRITON_DIR}/backends


# Allow more time to exit. Ensemble brings in too many models
SERVER_ARGS_EXTRA="--exit-timeout-secs=${SERVER_TIMEOUT} --backend-directory=${BACKEND_DIR} --backend-config=tensorflow,version=${TF_VERSION} --backend-config=python,stub-timeout-seconds=120"
SERVER_ARGS="--model-repository=${MODELDIR} ${SERVER_ARGS_EXTRA}"
SERVER_LOG_BASE="./inference_server"
source ../common/util.sh

rm -f $SERVER_LOG_BASE* $CLIENT_LOG_BASE*

RET=0

# If BACKENDS not specified, set to all
BACKENDS=${BACKENDS:="graphdef savedmodel"}
export BACKENDS

# If ENSEMBLES not specified, set to 1
ENSEMBLES=${ENSEMBLES:="1"}
export ENSEMBLES


SERVER_LOG=$SERVER_LOG_BASE.${TARGET}.log
CLIENT_LOG=$CLIENT_LOG_BASE.${TARGET}.log

rm -fr models && mkdir models
for BACKEND in $BACKENDS; do
  cp -r ${DATADIR}/qa_model_repository/${BACKEND}* \
    models/.

done

if [ "$ENSEMBLES" == "1" ]; then

  # Copy identity backend models and ensembles
  for BACKEND in $BACKENDS; do
    if [ "$BACKEND" != "python" ] && [ "$BACKEND" != "python_dlpack" ] && [ "$BACKEND" != "openvino" ]; then
        cp -r ${DATADIR}/qa_ensemble_model_repository/qa_model_repository/*${BACKEND}* \
          models/.
    fi
  done

  cp -r ${DATADIR}/qa_ensemble_model_repository/qa_model_repository/nop_* \
    models/.

  create_nop_version_dir `pwd`/models

  if [[ $BACKENDS == *"graphdef"* ]]; then
    ENSEMBLE_MODELS="wrong_label_int32_float32_float32 label_override_int32_float32_float32 mix_type_int32_float32_float32"

    ENSEMBLE_MODELS="${ENSEMBLE_MODELS} batch_to_nobatch_float32_float32_float32 batch_to_nobatch_nobatch_float32_float32_float32 nobatch_to_batch_float32_float32_float32 nobatch_to_batch_nobatch_float32_float32_float32 mix_nobatch_batch_float32_float32_float32"

    if [[ $BACKENDS == *"savedmodel"* ]] ; then
      ENSEMBLE_MODELS="${ENSEMBLE_MODELS} mix_platform_float32_float32_float32 mix_ensemble_int32_float32_float32"
    fi

    for EM in $ENSEMBLE_MODELS; do
      mkdir -p ../ensemble_models/$EM/1 && cp -r ../ensemble_models/$EM models/.
    done
  fi
fi

KIND="KIND_GPU" && [[ "$TARGET" == "cpu" ]] && KIND="KIND_CPU"

# Modify custom_zero_1_float32 and custom_nobatch_zero_1_float32 for relevant ensembles
# This is done after the instance group change above so that identity backend models
# are run on CPU. 
cp -r ../custom_models/custom_zero_1_float32 models/. &&\
    mkdir -p models/custom_zero_1_float32/1 && \
    (cd models/custom_zero_1_float32 && \
        echo "instance_group [ { kind: KIND_CPU }]" >> config.pbtxt)
cp -r models/custom_zero_1_float32 models/custom_nobatch_zero_1_float32 && \
    (cd models/custom_zero_1_float32 && \
        sed -i "s/max_batch_size: 1/max_batch_size: 8/" config.pbtxt && \
        sed -i "s/dims: \[ 1 \]/dims: \[ -1 \]/" config.pbtxt) && \
    (cd models/custom_nobatch_zero_1_float32 && \
        sed -i "s/custom_zero_1_float32/custom_nobatch_zero_1_float32/" config.pbtxt && \
        sed -i "s/max_batch_size: 1/max_batch_size: 0/" config.pbtxt && \
        sed -i "s/dims: \[ 1 \]/dims: \[ -1, -1 \]/" config.pbtxt)




set +e

python3 $INFER_TEST >$CLIENT_LOG 2>&1
if [ $? -ne 0 ]; then
    cat $CLIENT_LOG
    RET=1
else
    check_test_results $TEST_RESULT_FILE $EXPECTED_NUM_TESTS
    if [ $? -ne 0 ]; then
        cat $CLIENT_LOG
        echo -e "\n***\n*** Test Result Verification Failed\n***"
        RET=1
    fi
fi


set -e


if [ $RET -eq 0 ]; then
  echo -e "\n***\n*** Test Passed\n***"
else
  echo -e "\n***\n*** Test FAILED\n***"
fi

exit $RET