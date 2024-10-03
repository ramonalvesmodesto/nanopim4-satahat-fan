#!/bin/bash

###############################################################################
# Bash script to control the NanoPi M4 SATA hat 12v fan via the sysfs interface
###############################################################################
# Author: cgomesu
# Repo: https://github.com/cgomesu/nanopim4-satahat-fan
#
# Official pwm sysfs doc: https://www.kernel.org/doc/Documentation/pwm.txt
#
# This is free. There is NO WARRANTY. Use at your own risk.
###############################################################################

# DEFAULT_ variables are used in substitutions in case of missing the non-default variable.
# DEFAULT_ variables can be overriden by corresponding CLI args
DEFAULT_PWMCHIP='pwmchip0'
DEFAULT_CHANNEL='pwm0'
# setting the startup time to low values might affect the reliability of thermal controllers
DEFAULT_TIME_STARTUP=3
DEFAULT_TIME_LOOP=10
DEFAULT_MONIT_DEVICE='(soc|cpu)'
DEFAULT_TEMPS_SIZE=6
DEFAULT_THERMAL_ABS_THRESH_LOW=45
DEFAULT_THERMAL_ABS_THRESH_HIGH=78
DEFAULT_THERMAL_ABS_THRESH_OFF=0
DEFAULT_THERMAL_ABS_THRESH_ON=1
DEFAULT_DC_PERCENT_MIN=49
DEFAULT_DC_PERCENT_MAX=100
DEFAULT_PERIOD=25000000
DEFAULT_THERMAL_CONTROLLER='logistic'
# tunnable controller parameters
LOGISTIC_TEMP_CRITICAL=75
LOGISTIC_a=1
LOGISTIC_b=10
# uncomment and edit PID_THERMAL_IDEAL to set a fixed IDEAL temperature for the PID controller;
# otherwise, the initial temperature after startup (+2°C) is used as reference.
#PID_THERMAL_IDEAL=45
# https://en.wikipedia.org/wiki/PID_controller#Loop_tuning
PID_Kp=$((DEFAULT_PERIOD/100))
PID_Ki=$((DEFAULT_PERIOD/1000))
PID_Kd=$((DEFAULT_PERIOD/50))
# path to the pwm dir in the sysfs interface
PWMCHIP_ROOT='/sys/class/pwm/'
# path to the thermal dir in the sysfs interface
THERMAL_ROOT='/sys/class/thermal/'
# dir where temp files are stored. default caches to memory. be careful were you point this to
# because cleanup() will delete the directory.
CACHE_ROOT='/tmp/pwm-fan/'
# required packages and commands to run the script
REQUISITES=('bc' 'cat' 'echo' 'mkdir' 'touch' 'trap' 'sleep')

start () {
  echo '####################################################'
  echo '# STARTING PWM-FAN SCRIPT'
  echo "# Date and time: $(date)"
  echo '####################################################'
  check_requisites
}

# takes a message ($1) and its status ($2) as args
message () {
  echo "[pwm-fan] [$2] $1"
}

# takes message ($1) and exit status ($2) as arguments
end () {
  cleanup
  echo '####################################################'
  echo '# END OF THE PWM-FAN SCRIPT'
  echo "# MESSAGE: $1"
  echo '####################################################'
  exit "$2"
}

cleanup () {
  logger 'Cleaning up.' 'INFO'
  # disable the channel
  unexport_pwmchip_channel
  # clean cache files
  if [[ -d "$CACHE_ROOT" ]]; then
    rm -rf "$CACHE_ROOT"
  fi
}

cache () {
  local FILENAME
  if [[ -z "$1" ]]; then
    logger 'Cache file was not specified. Assuming generic.' 'INFO'
    FILENAME='generic'
  else
    FILENAME="$1"
  fi
  if [[ ! -d "$CACHE_ROOT" ]]; then
    mkdir "$CACHE_ROOT"
  fi
  CACHE="$CACHE_ROOT$FILENAME.cache"
  if [[ ! -f "$CACHE" ]]; then
    touch "$CACHE"
  else
    :> "$CACHE"
  fi
}

check_requisites () {
  logger "Checking requisites." 'INFO'
  for cmd in "${REQUISITES[@]}"; do
    if [[ -z $(command -v "$cmd") ]]; then
      logger "The following program is not installed or cannot be found in this users \$PATH: $cmd. Fix it and try again." 'ERROR'
      end "Missing important packages. Cannot continue." 1
    fi
  done
  logger 'All commands are accesible.' 'INFO'
}

export_pwmchip_channel () {
  if [[ ! -d "$CHANNEL_FOLDER" ]]; then
    local EXPORT
    EXPORT="$PWMCHIP_FOLDER"'export'
    cache 'export'
    echo 0 2> "$CACHE" > "$EXPORT"
    if [[ -n $(cat "$CACHE") ]]; then
      # on error, parse output
      local ERR_MSG
      if [[ $(cat "$CACHE") =~ (P|p)ermission\ denied ]]; then
        logger "This user does not have permission to use channel '${CHANNEL:-$DEFAULT_CHANNEL}'." 'ERROR'
        if [[ -n $(command -v stat) ]]; then
          logger "Export is owned by user '$(stat -c '%U' "$EXPORT" 2>/dev/null)' and group '$(stat -c '%G' "$EXPORT" 2>/dev/null)'." 'WARNING'
        fi
        ERR_MSG='User permission error while setting channel.'
      elif [[ $(cat "$CACHE") =~ (D|d)evice\ or\ resource\ busy ]]; then
        logger "It seems the pin is already in use. Cannot write to export." 'ERROR'
        ERR_MSG="'${PWMCHIP:-$DEFAULT_PWMCHIP}' was busy while setting the channel."
      else
        logger "There was an unknown error while setting the channel '${CHANNEL:-$DEFAULT_CHANNEL}'." 'ERROR'
        if [[ $(cat "$CACHE") =~ \ ([^\:]+)$ ]]; then
          logger "${BASH_REMATCH[1]}." 'WARNING'
        fi
        ERR_MSG='Unknown error while setting channel.'
      fi
      end "$ERR_MSG" 1
    fi
    sleep 1
  elif [[ -d "$CHANNEL_FOLDER" ]]; then
    logger "'${CHANNEL:-$DEFAULT_CHANNEL}' channel is already accessible." 'WARNING'
  fi
}

fan_initialization () {
  cache 'test_fan'
  local READ_MAX_DUTY_CYCLE
  READ_MAX_DUTY_CYCLE=$(cat "$CHANNEL_FOLDER"'period')
  echo "$READ_MAX_DUTY_CYCLE" 2> "$CACHE" > "$CHANNEL_FOLDER"'duty_cycle'
  # on error, try setting duty_cycle to a lower value
  if [[ -n $(cat "$CACHE") ]]; then
    READ_MAX_DUTY_CYCLE=$(($(cat "$CHANNEL_FOLDER"'period')-100))
    :> "$CACHE"
    echo "$READ_MAX_DUTY_CYCLE" 2> "$CACHE" > "$CHANNEL_FOLDER"'duty_cycle'
    if [[ -n $(cat "$CACHE") ]]; then
      end 'Unable to set max duty_cycle.' 1
    fi
  fi
  MAX_DUTY_CYCLE="$READ_MAX_DUTY_CYCLE"
  logger "Running fan at full speed for the next ${TIME_STARTUP:-$DEFAULT_TIME_STARTUP} seconds..." 'INFO'
  echo 1 > "$CHANNEL_FOLDER"'enable'
  sleep "${TIME_STARTUP:-$DEFAULT_TIME_STARTUP}"
  echo "$((MAX_DUTY_CYCLE/2))" > "$CHANNEL_FOLDER"'duty_cycle'
  logger "Initialization done. Duty cycle at 50% now: $((MAX_DUTY_CYCLE/2)) ns." 'INFO'
  sleep 1
}

fan_run () {
  if [[ "$THERMAL_STATUS" -eq 0 ]]; then
    fan_run_max
  else
    fan_run_thermal
  fi
}

fan_run_max () {
  logger "Running fan at full speed until stopped (Ctrl+C or kill '$$')..." 'INFO'
  while true; do
    echo "$MAX_DUTY_CYCLE" > "$CHANNEL_FOLDER"'duty_cycle'
    # run every so often to make sure it is maxed
    sleep 60
  done
}

fan_run_thermal () {
  logger "Running fan in temp monitor mode until stopped (Ctrl+C or kill '$$')..." 'INFO'
  THERMAL_ABS_THRESH=("${THERMAL_ABS_THRESH_LOW:-$DEFAULT_THERMAL_ABS_THRESH_LOW}" "${THERMAL_ABS_THRESH_HIGH:-$DEFAULT_THERMAL_ABS_THRESH_HIGH}")
  DC_ABS_THRESH=("$(((${DC_PERCENT_MIN:-$DEFAULT_DC_PERCENT_MIN}*MAX_DUTY_CYCLE)/100))" "$(((${DC_PERCENT_MAX:-$DEFAULT_DC_PERCENT_MAX}*MAX_DUTY_CYCLE)/100))")
  TEMPS=()
  while true; do
    TEMPS+=("$(thermal_meter)")
    # keep the array size lower or equal to TEMPS_SIZE
    if [[ "${#TEMPS[@]}" -gt "${TEMPS_SIZE:-$DEFAULT_TEMPS_SIZE}" ]]; then
      TEMPS=("${TEMPS[@]:1}")
    fi
    # determine if the fan should be OFF or ON
    if [[ "${TEMPS[-1]}" -le "${THERMAL_ABS_THRESH_OFF:-$DEFAULT_THERMAL_ABS_THRESH_OFF}" ]]; then
      echo "0" 2> /dev/null > "$CHANNEL_FOLDER"'duty_cycle'
    elif [[ "${TEMPS[-1]}" -ge "${THERMAL_ABS_THRESH_ON:-$DEFAULT_THERMAL_ABS_THRESH_ON}" ]]; then
      # only use a controller when within lower and upper thermal thresholds
      if [[ "${TEMPS[-1]}" -le "${THERMAL_ABS_THRESH[0]}" ]]; then
        echo "${DC_ABS_THRESH[0]}" 2> /dev/null > "$CHANNEL_FOLDER"'duty_cycle'
      elif [[ "${TEMPS[-1]}" -ge "${THERMAL_ABS_THRESH[-1]}" ]]; then
        echo "${DC_ABS_THRESH[-1]}" 2> /dev/null > "$CHANNEL_FOLDER"'duty_cycle'
      # the thermal array must be greater than one to use any controller, so skip the first iteration
      elif [[ "${#TEMPS[@]}" -gt 1 ]]; then
        if [[ "${THERMAL_CONTROLLER:-$DEFAULT_THERMAL_CONTROLLER}" == "logistic" ]]; then
          controller_logistic
        elif [[ "${THERMAL_CONTROLLER:-$DEFAULT_THERMAL_CONTROLLER}" == "pid" ]]; then
          controller_pid
        fi
      fi
    fi
    sleep "${TIME_LOOP:-$DEFAULT_TIME_LOOP}"
  done
}

fan_startup () {
  while [[ -d "$CHANNEL_FOLDER" ]]; do
    if [[ $(cat "$CHANNEL_FOLDER"'enable') -eq 0 ]]; then
      set_default; break
    elif [[ $(cat "$CHANNEL_FOLDER"'enable') -eq 1 ]]; then
      logger 'The fan is already enabled. Will disable it.' 'WARNING'
      echo 0 > "$CHANNEL_FOLDER"'enable'
      sleep 1
      set_default; break
    else
      logger 'Unable to read the fan enable status.' 'ERROR'
      end 'Bad fan status.' 1
    fi
  done
}

# takes 'x' 'x0' 'L' 'a' 'b' as arguments
function_logistic () {
  # https://en.wikipedia.org/wiki/Logistic_function
  # k=a/b
  local x x0 L a b equation result
  x="$1"; x0="$2"; L="$3"; a="$4"; b="$5"
  equation="output=($L)/(1+e(-($a/$b)*($x-$x0)))"
  result=$(echo "scale=4;$equation;scale=0;output/1" | bc -lq 2>/dev/null)
  echo "$result"
}

# logic for the logistic controller
controller_logistic () {
  local temp temps_sum mean_temp dev_mean_critical x0 model
  temps_sum=0
  for temp in "${TEMPS[@]}"; do
    ((temps_sum+=temp))
  done
  # moving mid-point
  mean_temp="$((temps_sum/${#TEMPS[@]}))"
  dev_mean_critical="$((mean_temp-LOGISTIC_TEMP_CRITICAL))"
  x0="${dev_mean_critical#-}"
  # function_logistic args: 'x' 'x0' 'L' 'a' 'b'
  # the model is adjusted to ns and bound to the upper (raw) DC threshold value because of L="${DC_ABS_THRESH[-1]}"
  model=$(function_logistic "${TEMPS[-1]}" "$x0" "${DC_ABS_THRESH[-1]}" "$LOGISTIC_a" "$LOGISTIC_b")
  # bound to duty cycle thresholds first in case model-based value is outside the valid range
  if [[ "$model" -lt "${DC_ABS_THRESH[0]}" ]]; then
    echo "${DC_ABS_THRESH[0]}" 2> /dev/null > "$CHANNEL_FOLDER"'duty_cycle'
  elif [[ "$model" -gt "${DC_ABS_THRESH[-1]}" ]]; then
    echo "${DC_ABS_THRESH[-1]}" 2> /dev/null > "$CHANNEL_FOLDER"'duty_cycle'
  else
    echo "$model" 2> /dev/null > "$CHANNEL_FOLDER"'duty_cycle'
  fi
}

# takes 'p_error' 'i_error' 'd_error' 'Kp' 'Ki' 'Kd' as arguments
function_pid () {
  # https://en.wikipedia.org/wiki/PID_controller
  local p_e i_e d_e Kp Ki Kd equation result
  p_e="$1"; i_e="$2"; d_e="$3"; Kp="$4"; Ki="$5"; Kd="$6"
  equation="output=($Kp*$p_e)+($Ki*$i_e)+($Kd*$d_e)"
  result=$(echo "scale=4;$equation;scale=0;output/1" | bc -lq 2>/dev/null)
  echo "$result"
}

# logic for the PID controller
controller_pid () {
  # i_error cannot be local to be cumulative since it was first declared.
  local p_error d_error model duty_cycle
  p_error="$((${TEMPS[-1]}-${PID_THERMAL_IDEAL:-$((THERMAL_INITIAL+2))}))"
  i_error="$((${i_error:-0}+p_error))"
  d_error="$((${TEMPS[-1]}-${TEMPS[-2]}))"
  # TODO: Kp, Ki, and Kd could be auto tunned here; currently, they are not declared and PID_ vars are used.
  # function_pid args: 'p_error' 'i_error' 'd_error' 'Kp' 'Ki' 'Kd'
  model="$(function_pid "$p_error" "$i_error" "$d_error" "${Kp:-$PID_Kp}" "${Ki:-$PID_Ki}" "${Kd:-$PID_Kd}")"
  duty_cycle="$(cat "$CHANNEL_FOLDER"'duty_cycle')"
  # bound to duty cycle thresholds first in case model-based value is outside the valid range
  if [[ $((duty_cycle+model)) -lt "${DC_ABS_THRESH[0]}" ]]; then
    echo "${DC_ABS_THRESH[0]}" 2> /dev/null > "$CHANNEL_FOLDER"'duty_cycle'
    # reset i_error to prevent from acumulating further
    i_error=0
  elif [[ $((duty_cycle+model)) -gt "${DC_ABS_THRESH[-1]}" ]]; then
    echo "${DC_ABS_THRESH[-1]}" 2> /dev/null > "$CHANNEL_FOLDER"'duty_cycle'
    # reset i_error to prevent from acumulating further
    i_error=0
  else
    echo $((duty_cycle+model)) 2> /dev/null > "$CHANNEL_FOLDER"'duty_cycle'
  fi
}

pwmchip () {
  PWMCHIP_FOLDER="$PWMCHIP_ROOT${PWMCHIP:-$DEFAULT_PWMCHIP}"'/'
  if [[ ! -d "$PWMCHIP_FOLDER" ]]; then
    logger "The sysfs interface for the '${PWMCHIP:-$DEFAULT_PWMCHIP}' is not accessible." 'ERROR'
    end "Unable to access a sysfs interface." 1
  fi
  logger "Working with the sysfs interface for the '${PWMCHIP:-$DEFAULT_PWMCHIP}'." 'INFO'
  logger "For reference, your '${PWMCHIP:-$DEFAULT_PWMCHIP}' supports '$(cat "$PWMCHIP_FOLDER"'npwm')' channel(s)." 'INFO'
  CHANNEL_FOLDER="$PWMCHIP_FOLDER${CHANNEL:-$DEFAULT_CHANNEL}"'/'
}

set_default () {
  cache 'set_default_duty_cycle'
  echo 0 2> "$CACHE" > "$CHANNEL_FOLDER"'duty_cycle'
  if [[ -n $(cat "$CACHE") ]]; then
    # set higher than 0 values to avoid negative ones
    echo 100 > "$CHANNEL_FOLDER"'period'
    echo 10 > "$CHANNEL_FOLDER"'duty_cycle'
  fi
  cache 'set_default_period'
  echo "${PERIOD:-$DEFAULT_PERIOD}" 2> "$CACHE" > "$CHANNEL_FOLDER"'period'
  if [[ -n $(cat "$CACHE") ]]; then
    logger "The period provided ('${PERIOD:-$DEFAULT_PERIOD}') is not acceptable." 'WARNING'
    logger 'Trying to lower it by 100ns decrements. This may take a while...' 'WARNING'
    local decrement rate PERIOD_NEW
    decrement=100; rate=$decrement
    until [[ "$PERIOD_NEW" -le 200 ]]; do
      PERIOD_NEW=$((PERIOD-rate))
      :> "$CACHE"
      echo "$PERIOD_NEW" 2> "$CACHE" > "$CHANNEL_FOLDER"'period'
      if [[ -z $(cat "$CACHE") ]]; then
        break
      fi
      rate=$((rate+decrement))
    done
    PERIOD="$PERIOD_NEW"
    if [[ "$PERIOD" -le 100 ]]; then
      end 'Unable to set an appropriate value for the period.' 1
    fi
  fi
  echo 'normal' > "$CHANNEL_FOLDER"'polarity'
  logger "Default polarity: $(cat "$CHANNEL_FOLDER"'polarity')" 'INFO'
  logger "Default period: $(cat "$CHANNEL_FOLDER"'period') ns" 'INFO'
  logger "Default duty cycle: $(cat "$CHANNEL_FOLDER"'duty_cycle') ns" 'INFO'
}

thermal_meter () {
  if [[ -f "$TEMP_FILE" ]]; then
    local TEMP; TEMP=$(cat "$TEMP_FILE" 2> /dev/null)
    # TEMP is in millidegrees, so convert to degrees
    echo "$((TEMP/1000))"
  fi
}

thermal_monit () {
  if [[ -d "$THERMAL_ROOT" && -z "$SKIP_THERMAL" ]]; then
    for dir in "$THERMAL_ROOT"'thermal_zone'*; do
      if [[ $(cat "$dir"'/type') =~ ${MONIT_DEVICE:-$DEFAULT_MONIT_DEVICE} && -f "$dir"'/temp' ]]; then
        TEMP_FILE="$dir"'/temp'
        THERMAL_INITIAL="$(thermal_meter)"
        logger "Found the '${MONIT_DEVICE:-$DEFAULT_MONIT_DEVICE}' temperature at '$TEMP_FILE'." 'INFO'
        logger "Current '${MONIT_DEVICE:-$DEFAULT_MONIT_DEVICE}' temp is: $THERMAL_INITIAL Celsius" 'INFO'
        logger "Setting fan to monitor the '${MONIT_DEVICE:-$DEFAULT_MONIT_DEVICE}' temperature." 'INFO'
        THERMAL_STATUS=1
        return
      fi
    done
    logger "Did not find the temperature for the device type: ${MONIT_DEVICE:-$DEFAULT_MONIT_DEVICE}" 'WARNING'
  else
    logger "The '-f' mode was enabled or the the thermal zone cannot be found at '$THERMAL_ROOT'." 'WARNING'
  fi
  logger "Setting fan to operate independent of the '${MONIT_DEVICE:-$DEFAULT_MONIT_DEVICE}' temperature." 'WARNING'
  THERMAL_STATUS=0
}

unexport_pwmchip_channel () {
  if [[ -d "$CHANNEL_FOLDER" ]]; then
    logger "Freeing up the channel '${CHANNEL:-$DEFAULT_CHANNEL}' controlled by the '${PWMCHIP:-$DEFAULT_PWMCHIP}'." 'INFO'
    echo 0 > "$CHANNEL_FOLDER"'enable'
    sleep 1
    echo 0 > "$PWMCHIP_FOLDER"'unexport'
    sleep 1
    if [[ ! -d "$CHANNEL_FOLDER" ]]; then
      logger "Channel '${CHANNEL:-$DEFAULT_CHANNEL}' was successfully disabled." 'INFO'
    else
      logger "Channel '${CHANNEL:-$DEFAULT_CHANNEL}' is still enabled but it should not be. Check '$CHANNEL_FOLDER'." 'WARNING'
    fi
  else
    logger 'There is no channel to disable.' 'WARNING'
  fi
}

usage() {
  echo ''
  echo 'Usage:'
  echo ''
  echo "$0 [OPTIONS]"
  echo ''
  echo '  Options:'
  echo '    -c  str  Name of the PWM CHANNEL (e.g., pwm0, pwm1). Default: pwm0'
  echo '    -C  str  Name of the PWM CONTROLLER (e.g., pwmchip0, pwmchip1). Default: pwmchip1'
  echo '    -d  int  Lowest DUTY CYCLE threshold (in percentage of the period). Default: 25'
  echo '    -D  int  Highest DUTY CYCLE threshold (in percentage of the period). Default: 100'
  echo '    -f       Fan runs at FULL SPEED all the time. If omitted (default), speed depends on temperature.'
  echo '    -F  int  TIME (in seconds) to run the fan at full speed during STARTUP. Default: 60'
  echo '    -h       Show this HELP message.'
  echo '    -l  int  TIME (in seconds) to LOOP thermal reads. Lower means higher resolution but uses ever more resources. Default: 10'
  echo '    -m  str  Name of the DEVICE to MONITOR the temperature in the thermal sysfs interface. Default: (soc|cpu)'
  echo '    -o  str  Name of the THERMAL CONTROLLER. Options: logistic (default), pid.'
  echo '    -p  int  The fan PERIOD (in nanoseconds). Default (25kHz): 25000000.'
  echo '    -s  int  The MAX SIZE of the TEMPERATURE ARRAY. Interval between data points is set by -l. Default (store last 1min data): 6.'
  echo '    -t  int  Lowest TEMPERATURE threshold (in Celsius). Lower temps set the fan speed to min. Default: 25'
  echo '    -T  int  Highest TEMPERATURE threshold (in Celsius). Higher temps set the fan speed to max. Default: 75'
  echo '    -u  int  Fan-off TEMPERATURE threshold (in Celsius). Shuts off fan under the specified temperature. Default: 0'
  echo '    -U  int  Fan-on TEMPERATURE threshold (in Celsius). Turn on fan control above the specified temperature. Default: 1'
  echo ''
  echo '  If no options are provided, the script will run with default values.'
  echo '  Defaults have been tested and optimized for the following hardware:'
  echo '    -  NanoPi-M4 v2'
  echo '    -  M4 SATA hat'
  echo '    -  Fan 12V (.08A and .2A)'
  echo '  And software:'
  echo '    -  Kernel: Linux 4.4.231-rk3399'
  echo '    -  OS: Armbian Buster (20.08.9) stable'
  echo '    -  GNU bash v5.0.3'
  echo '    -  bc v1.07.1'
  echo ''
  echo 'Author: cgomesu'
  echo 'Repo: https://github.com/cgomesu/nanopim4-satahat-fan'
  echo ''
  echo 'This is free. There is NO WARRANTY. Use at your own risk.'
  echo ''
}


############
# main logic
while getopts 'c:C:d:D:fF:hl:m:o:p:s:t:T:u:U:' OPT; do
  case ${OPT} in
    c)
      CHANNEL="$OPTARG"
      if [[ ! "$CHANNEL" =~ ^pwm[0-9]+$ ]]; then
        logger "The value for the '-c' argument ($CHANNEL) is invalid." 'ERROR'
        logger 'The name of the pwm channel must contain pwm and at least one integer (pwm0).' 'ERROR'
        exit 1
      fi
      ;;
    C)
      PWMCHIP="$OPTARG"
      if [[ ! "$PWMCHIP" =~ ^pwmchip[0-9]+$ ]]; then
        logger "The value for the '-C' argument ($PWMCHIP) is invalid." 'ERROR'
        logger 'The name of the pwm controller must contain pwmchip and at least one integer (pwmchip1).' 'ERROR'
        exit 1
      fi
      ;;
    d)
      DC_PERCENT_MIN="$OPTARG"
      if [[ ! "$DC_PERCENT_MIN" =~ ^[0-4]?[0-9]$ ]]; then
        logger "The value for the '-d' argument ($DC_PERCENT_MIN) is invalid." 'ERROR'
        logger 'The lowest duty cycle threshold must be an integer between 0 and 49.' 'ERROR'
        exit 1
      fi
      ;;
    D)
      DC_PERCENT_MAX="$OPTARG"
      if [[ ! "$DC_PERCENT_MAX" =~ ^([5-9][0-9]|100)$ ]]; then
        logger "The value for the '-D' argument ($DC_PERCENT_MAX) is invalid." 'ERROR'
        logger 'The highest duty cycle threshold must be an integer between 50 and 100.' 'ERROR'
        exit 1
      fi
      ;;
    f)
      SKIP_THERMAL=1
      ;;
    F)
      TIME_STARTUP="$OPTARG"
      if [[ ! "$TIME_STARTUP" =~ ^[0-9]+$ ]]; then
        logger "The value for the '-F' argument ($TIME_STARTUP) is invalid." 'ERROR'
        logger 'The time to run the fan at full speed during startup must be an integer.' 'ERROR'
        exit 1
      fi
      ;;
    h)
      usage
      exit 0
      ;;
    l)
      TIME_LOOP="$OPTARG"
      if [[ ! "$TIME_LOOP" =~ ^[0-9]+$ ]]; then
        logger "The value for the '-l' argument ($TIME_LOOP) is invalid." 'ERROR'
        logger 'The time to loop thermal reads must be an integer.' 'ERROR'
        exit 1
      fi
      ;;
    m)
      MONIT_DEVICE="$OPTARG"
      ;;
    o)
      THERMAL_CONTROLLER="$OPTARG"
      if [[ ! "$THERMAL_CONTROLLER" =~ ^(logistic|pid)$ ]]; then
        logger "The value for the '-o' argument ($THERMAL_CONTROLLER) is invalid." 'ERROR'
        logger "The thermal controller must be either 'logistic' or 'pid'." 'ERROR'
        exit 1
      fi
      ;;
    p)
      PERIOD="$OPTARG"
      if [[ ! "$PERIOD" =~ ^[0-9]+$ ]]; then
        logger "The value for the '-p' argument ($PERIOD) is invalid." 'ERROR'
        logger 'The period must be an integer.' 'ERROR'
        exit 1
      fi
      ;;
    s)
      TEMPS_SIZE="$OPTARG"
      if [[ "$TEMPS_SIZE" -le 1 || ! "$TEMPS_SIZE" =~ ^[0-9]+$ ]]; then
        logger "The value for the '-s' argument ($TEMPS_SIZE) is invalid." 'ERROR'
        logger 'The max size of the temperature array must be an integer greater than 1.' 'ERROR'
        exit 1
      fi
      ;;
    t)
      THERMAL_ABS_THRESH_LOW="$OPTARG"
      if [[ ! "$THERMAL_ABS_THRESH_LOW" =~ ^[0-5]?[0-9]$ ]]; then
        logger "The value for the '-t' argument ($THERMAL_ABS_THRESH_LOW) is invalid." 'ERROR'
        logger 'The lowest temperature threshold must be an integer between 0 and 59.' 'ERROR'
        exit 1
      fi
      ;;
    T)
      THERMAL_ABS_THRESH_HIGH="$OPTARG"
      if [[ ! "$THERMAL_ABS_THRESH_HIGH" =~ ^([6-9][0-9]|1[0-1][0-9]|120)$ ]]; then
        logger "The value for the '-T' argument ($THERMAL_ABS_THRESH_HIGH) is invalid." 'ERROR'
        logger 'The highest temperature threshold must be an integer between 60 and 120.' 'ERROR'
        exit 1
      fi
      ;;
    u)
      THERMAL_ABS_THRESH_OFF="$OPTARG"
      if [[ ! "$THERMAL_ABS_THRESH_OFF" =~ ^[0-5]?[0-9]$ ]]; then
        logger "The value for the '-u' argument ($THERMAL_ABS_THRESH_OFF) is invalid." 'ERROR'
        logger 'The OFF temperature threshold must be an integer between 0 and 59.' 'ERROR'
        exit 1
      fi
      ;;
    U)
      THERMAL_ABS_THRESH_ON="$OPTARG"
      if [[ "$THERMAL_ABS_THRESH_ON" -le "$THERMAL_ABS_THRESH_OFF" || ! "$THERMAL_ABS_THRESH_ON" =~ ^[0-9]+$ ]]; then
        logger "The value for the '-U' argument ($THERMAL_ABS_THRESH_ON) is invalid." 'ERROR'
        logger 'The ON temperature threshold (-U) must be an integer strictly greater than the OFF temperature threshold (-u).' 'ERROR'
        exit 1
      fi
      ;;
    \?)
      echo ''
      echo '................................'
      echo 'Detected an invalid option.'
      echo "Check args or see '$0 -h'."
      echo '................................'
      echo ''
      exit 1
      ;;
  esac
done

start
trap "echo ''; end 'Received a signal to stop the script.' 0" INT HUP TERM

# configuration functions
pwmchip
export_pwmchip_channel
fan_startup
fan_initialization
thermal_monit

# run functions
fan_run
