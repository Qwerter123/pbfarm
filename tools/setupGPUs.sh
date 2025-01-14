#!/bin/bash

#   Copyright 2021 rdugan
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

if [ $# != 2 ] || \
   [[ ! $1 =~ ^([0-9](,[0-9])*|all)$ ]] || \
   [[ ! $2 =~ ^(mw29|mw31|cng|cnv2|cnh|cnt|ccx|eth|nim|kawpow|ergo)$ ]];
then
  echo "$0 <N[,N]>|all mw29|mw31|cng|cnv2|cnh|cnt|ccx|eth|nim|kawpow|ergo"
  exit 1
fi

cd $(dirname $0)

DEVICES="$1"
COIN=$2
ALGO=$COIN

CONFIG_FILE="../config/json/$ALGO.json"
PPT_DIR="../config/ppts"

declare -a GPUS
declare -A STATES
declare -A TIMINGS
declare -A ATITOOL_SETTINGS

if [[ $DEVICES =~ ^[0-9] ]]; then
  GPUS=(${DEVICES//,/ })
else
  readarray -t GPUS <<< `./PCI_DRM_map.sh |cut -d' ' -f2`
fi

config=`jq '.' $CONFIG_FILE`
if [[ -z $config ]]; then
  echo "Missing or malformed config file $(readlink -f $CONFIG_FILE)"
  exit 1
fi

defaultHashrate=`jq '.configDefaults.hashrateTarget' <<< "$config"`
defaultPPTFile=`jq '.configDefaults.pptFile' <<< "$config"`

defaultTimings=`jq '.configDefaults.timings' <<< "$config"`
defaultStates=`jq '.configDefaults.states' <<< "$config"`
defaultVoltages=`jq '.configDefaults.voltages' <<< "$config"`

for i in "${GPUS[@]}"
do
  deviceConfig=`jq --argjson i "$i" '.devices[] | select(.drmID == $i)' $CONFIG_FILE`

  HR_TARGET=`jq '.config? | .hashrateTarget' <<< "$deviceConfig"`
  [[ ! -z $HR_TARGET ]] && HR_TARGET=$defaultHashrate
  HR_TARGET="${HR_TARGET//./$''}"

  DRM_ID=$i
  I2C_ID=`jq '.i2cID' <<< "$deviceConfig"`
  GPU_ARCH=`jq '.arch' <<< "$deviceConfig"`

  # get device specific ppt filename template if exists
  pptFile=`jq '.config? | .pptFile' <<< "$deviceConfig"`
  [[ ! -z $pptFile ]] && pptFile=$defaultPPTFile
  # get full filename by populating placeholders
  eval PPTS[$i]="$pptFile"

  # get device specific timings
  deviceTimings=`jq '.config? | .timings' <<< "$deviceConfig"`
  # merge default and device timings
  timings=`echo "$defaultTimings $deviceTimings" | jq -s add`
  # build timings string
  for k in `jq -r '. | keys[]' <<< "$timings"`
  do
    v=`jq --arg k "$k" -r '.[$k]' <<< "$timings"`
    TIMINGS[$i]+="--$k $v "
  done

  # get device specific DPM states
  deviceStates=`jq '.config? | .states' <<< "$deviceConfig"`
  # merge default and device states
  states=`echo "$defaultStates $deviceStates" | jq -s add`
  # extract core, mem, and soc state values from object
  states=`jq -r '.core, .mem, .soc' <<< "$states"`
  # convert jq string output to array
  states=($states)
  # add states to device array, stripping soc if null
  STATES[$i]=${states[@]/null}

  # get device specific atitool voltages
  deviceVoltages=`jq '.config? | .voltages' <<< "$deviceConfig"`
  # merge default and device voltages
  voltages=`echo "$defaultVoltages $deviceVoltages" | jq -s add`
  # build voltages string
  for k in `jq -r '. | keys[]' <<< "$voltages"`
  do
    v=`jq --arg k "$k" -r '.[$k]' <<< "$voltages"`
    if [[ $k =~ vddcr_hbm ]] && [[ $GPU_ARCH =~ "Vega 20" ]]; then
      # mvddc control doesn't work in atitool - need to use i2c instead
      mvddc_increment="0.00625"
      mvddc_index=`echo "obase=16; ($v-$mvddc_increment)/($mvddc_increment*2)" | bc`
      I2C_SETTINGS[$i]="$I2C_ID 0x32 0xe3 0x${mvddc_index}"
    else
      ATITOOL_SETTINGS[$i]+="-$k=$v "
    fi
  done
done

for i in "${GPUS[@]}"
do
  # apply soft powerplay tables
  [[ ! -z "${PPTS[$i]:-}" ]] && ./setPPT.sh $i "${PPT_DIR}/${PPTS[$i]}"

  # set powerplay states and mem timings
  [[ ! -z "${STATES[$i]:-}" ]] && ./setGPUState.sh $i ${STATES[$i]}
  [[ ! -z "${TIMINGS[$i]:-}" ]] && ./amdmemtweak --i $i ${TIMINGS[$i]}

  # non-standard voltage settings
  [[ ! -z "${I2C_SETTINGS[$i]:-}" ]] && i2cset -y -r ${I2C_SETTINGS[$i]}
  [[ ! -z "${ATITOOL_SETTINGS[$i]:-}" ]] && ./atitool -i=$i ${ATITOOL_SETTINGS[$i]}

#  ./disable_ecc.sh $i
done
