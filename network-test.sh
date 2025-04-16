#!/bin/bash
# network_test.sh - Unified network testing script for RHEL 9.4 with CSV logging

LOG_FILE="network_test_log.csv"
[[ ! -f "$LOG_FILE" ]] && echo "timestamp,test_type,destination,proxy,metric,value" > "$LOG_FILE"

usage() {
  echo "Usage: $0 --dest <destination> [--proxy <ip:port>] [--test latency|wget|iperf3|all]"
  exit 1
}

DEST=""
PROXY=""
TEST_TYPE="all"

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --dest) DEST="$2"; shift ;;
    --proxy) PROXY="$2"; shift ;;
    --test) TEST_TYPE="$2"; shift ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
  shift
done

[[ -z "$DEST" ]] && { echo "Destination is required."; usage; }

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

log_result() {
  local type=$1
  local metric=$2
  local value=$3
  echo "$(timestamp),$type,$DEST,${PROXY:-none},$metric,$value" >> "$LOG_FILE"
}

run_latency() {
  echo -e "\n[Latency Test]"

  if [[ "$DEST" == http* ]]; then
    echo "--> HTTP Latency (Direct)"
    result=$(curl -o /dev/null -s -w "%{time_total}" "$DEST")
    echo "Time: ${result}s"
    log_result "latency" "http_direct" "$result"

    if [[ -n "$PROXY" ]]; then
      echo "--> HTTP Latency (Via Proxy)"
      result=$(curl -o /dev/null -s -w "%{time_total}" -x "$PROXY" "$DEST")
      echo "Time: ${result}s"
      log_result "latency" "http_proxy" "$result"
    fi
  else
    echo "--> Ping Latency"
    result=$(ping -c 5 "$DEST" | awk -F '/' 'END{ print $(NF-1) }')
    echo "Avg Latency: ${result}ms"
    log_result "latency" "ping" "$result"
  fi
}

run_wget_bandwidth() {
  echo -e "\n[Bandwidth Test - wget]"

  echo "--> Direct Download"
  result=$( (time wget --output-document=/dev/null "$DEST") 2>&1 | grep real | awk '{print $2}')
  seconds=$(echo "$result" | awk -Fm '{print ($1*60)+$2}')
  echo "Time: ${seconds}s"
  log_result "wget" "direct_time" "$seconds"

  if [[ -n "$PROXY" ]]; then
    echo "--> Proxy Download"
    result=$( (time wget --output-document=/dev/null -e use_proxy=yes -e http_proxy="http://$PROXY" "$DEST") 2>&1 | grep real | awk '{print $2}')
    seconds=$(echo "$result" | awk -Fm '{print ($1*60)+$2}')
    echo "Time: ${seconds}s"
    log_result "wget" "proxy_time" "$seconds"
  fi
}

run_iperf3() {
  echo -e "\n[Bandwidth Test - iperf3]"

  result=$(iperf3 -c "$DEST" 2>/dev/null | grep -A1 "receiver" | grep -Eo '[0-9.]+ Mbits/sec')
  echo "Speed: ${result:-N/A}"
  log_result "iperf3" "direct_speed" "${result:-N/A}"
}

echo "=== Running Network Test ==="
echo "Destination: $DEST"
[[ -n "$PROXY" ]] && echo "Proxy: $PROXY"
echo "Test Type: $TEST_TYPE"
echo "Results will be logged to $LOG_FILE"
echo "======================================="

case $TEST_TYPE in
  latency) run_latency ;;
  wget) run_wget_bandwidth ;;
  iperf3) run_iperf3 ;;
  all)
    run_latency
    run_wget_bandwidth
    run_iperf3
    ;;
  *) echo "Invalid test type: $TEST_TYPE"; usage ;;
esac

