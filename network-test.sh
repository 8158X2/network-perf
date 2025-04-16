#!/bin/bash
# build 0001
# network_test.sh - Unified network testing script for RHEL 9.4 with CSV logging

LOG_FILE="network_test_log.csv"
SUMMARY_FILE="network_test_summary.csv"
PLOT_DIR="network_plots"
[[ ! -f "$LOG_FILE" ]] && echo "timestamp,test_type,destination,proxy,metric,value" > "$LOG_FILE"
mkdir -p "$PLOT_DIR"

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

generate_summary() {
  echo "Generating summary report..."
  local summary_file="$SUMMARY_FILE"
  
  # Create summary header
  echo "timestamp,ping_latency,http_direct_latency,http_proxy_latency,wget_direct_time,wget_proxy_time,iperf3_speed" > "$summary_file"
  
  # Process the log file to create a summary
  awk -F',' '
    NR>1 {
      timestamp=$1
      test_type=$2
      metric=$5
      value=$6
      
      # Initialize arrays for this timestamp if not exists
      if (!(timestamp in data)) {
        data[timestamp]["ping"] = "N/A"
        data[timestamp]["http_direct"] = "N/A"
        data[timestamp]["http_proxy"] = "N/A"
        data[timestamp]["wget_direct"] = "N/A"
        data[timestamp]["wget_proxy"] = "N/A"
        data[timestamp]["iperf3"] = "N/A"
      }
      
      # Store the value based on test type and metric
      if (test_type == "latency") {
        if (metric == "ping") data[timestamp]["ping"] = value
        else if (metric == "http_direct") data[timestamp]["http_direct"] = value
        else if (metric == "http_proxy") data[timestamp]["http_proxy"] = value
      }
      else if (test_type == "wget") {
        if (metric == "direct_time") data[timestamp]["wget_direct"] = value
        else if (metric == "proxy_time") data[timestamp]["wget_proxy"] = value
      }
      else if (test_type == "iperf3") {
        if (metric == "direct_speed") data[timestamp]["iperf3"] = value
      }
    }
    END {
      for (ts in data) {
        printf "%s,%s,%s,%s,%s,%s,%s\n", 
          ts, 
          data[ts]["ping"],
          data[ts]["http_direct"],
          data[ts]["http_proxy"],
          data[ts]["wget_direct"],
          data[ts]["wget_proxy"],
          data[ts]["iperf3"]
      }
    }
  ' "$LOG_FILE" | sort >> "$summary_file"
}

generate_plots() {
  echo "Generating plots..."
  
  # Check if Python is installed
  if ! command -v python3 &> /dev/null; then
    echo "Warning: Python3 is not installed. Please install it to generate plots."
    echo "On RHEL: sudo dnf install python3 python3-pip"
    return
  fi
  
  # Create a simpler Python plotting script
  cat > plot_script.py << 'EOF'
import pandas as pd
import matplotlib.pyplot as plt

try:
    # Read the summary data
    df = pd.read_csv('network_test_summary.csv')
    df['timestamp'] = pd.to_datetime(df['timestamp'])

    # Create a single plot
    plt.figure(figsize=(12, 8))
    
    # Plot each metric
    if 'ping_latency' in df.columns:
        plt.plot(df['timestamp'], df['ping_latency'], label='Ping Latency', marker='o')
    if 'http_direct_latency' in df.columns:
        plt.plot(df['timestamp'], df['http_direct_latency'], label='HTTP Direct', marker='s')
    if 'wget_direct_time' in df.columns:
        plt.plot(df['timestamp'], df['wget_direct_time'], label='Wget Time', marker='^')
    if 'iperf3_speed' in df.columns:
        plt.plot(df['timestamp'], df['iperf3_speed'].str.replace(' Mbits/sec', '').astype(float), 
                label='iPerf3 Speed', marker='x')

    # Format the plot
    plt.title('Network Performance Over Time')
    plt.xlabel('Time')
    plt.ylabel('Value')
    plt.grid(True)
    plt.legend()
    plt.xticks(rotation=45)
    
    # Save the plot
    plt.tight_layout()
    plt.savefig('network_plots/network_performance.png', dpi=300)
    print("Plot generated successfully")
except Exception as e:
    print(f"Error generating plot: {str(e)}")
EOF

  # Check if required Python packages are installed
  if ! python3 -c "import pandas, matplotlib" 2>/dev/null; then
    echo "Installing required Python packages..."
    python3 -m pip install pandas matplotlib --user
  fi

  # Generate plots
  python3 plot_script.py
  rm plot_script.py
}

# Generate summary and plots after tests
generate_summary
generate_plots

echo -e "\nTest results have been logged to:"
echo "- Detailed log: $LOG_FILE"
echo "- Summary report: $SUMMARY_FILE"
echo "- Plots: $PLOT_DIR/*.png"

