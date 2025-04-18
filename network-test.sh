#!/bin/bash
# build 0002
# network_test.sh - Unified network testing script for RHEL 9.4 with CSV logging

# Define log files
LATENCY_LOG="latency_test_log.csv"
WGET_LOG="wget_test_log.csv"
IPERF_LOG="iperf_test_log.csv"
SUMMARY_FILE="network_test_summary.csv"
PLOT_DIR="network_plots"

# Create log files with headers if they don't exist
[[ ! -f "$LATENCY_LOG" ]] && echo "timestamp,test_type,destination,proxy,metric,value" > "$LATENCY_LOG"
[[ ! -f "$WGET_LOG" ]] && echo "timestamp,test_type,destination,proxy,metric,value" > "$WGET_LOG"
[[ ! -f "$IPERF_LOG" ]] && echo "timestamp,test_type,destination,proxy,metric,value" > "$IPERF_LOG"
mkdir -p "$PLOT_DIR"

usage() {
  echo "Usage: $0 [--dest <destination>] [--latency-dest <destination>] [--wget-dest <destination>] [--iperf-dest <destination>] [--proxy <ip:port>] [--test latency|wget|iperf3|all]"
  echo "Note: If specific test destinations are not provided, --dest will be used as fallback"
  exit 1
}

DEST=""
LATENCY_DEST=""
WGET_DEST=""
IPERF_DEST=""
PROXY=""
TEST_TYPE="all"

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --dest) DEST="$2"; shift ;;
    --latency-dest) LATENCY_DEST="$2"; shift ;;
    --wget-dest) WGET_DEST="$2"; shift ;;
    --iperf-dest) IPERF_DEST="$2"; shift ;;
    --proxy) PROXY="$2"; shift ;;
    --test) TEST_TYPE="$2"; shift ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
  shift
done

# Use fallback destinations if specific ones are not provided
[[ -z "$LATENCY_DEST" ]] && LATENCY_DEST="$DEST"
[[ -z "$WGET_DEST" ]] && WGET_DEST="$DEST"
[[ -z "$IPERF_DEST" ]] && IPERF_DEST="$DEST"

# Check if at least one destination is provided
if [[ -z "$DEST" && -z "$LATENCY_DEST" && -z "$WGET_DEST" && -z "$IPERF_DEST" ]]; then
  echo "At least one destination is required."
  usage
fi

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

log_result() {
  local type=$1
  local metric=$2
  local value=$3
  local dest=$4
  local log_file
  
  case $type in
    latency) log_file="$LATENCY_LOG" ;;
    wget) log_file="$WGET_LOG" ;;
    iperf3) log_file="$IPERF_LOG" ;;
    *) log_file="network_test_log.csv" ;;
  esac
  
  echo "$(timestamp),$type,$dest,${PROXY:-none},$metric,$value" >> "$log_file"
}

run_latency() {
  echo -e "\n[Latency Test]"
  echo "Destination: $LATENCY_DEST"

  if [[ "$LATENCY_DEST" == http* ]]; then
    echo "--> HTTP Latency (Direct)"
    result=$(curl -o /dev/null -s -w "%{time_total}" "$LATENCY_DEST")
    echo "Time: ${result}s"
    log_result "latency" "http_direct" "$result" "$LATENCY_DEST"

    if [[ -n "$PROXY" ]]; then
      echo "--> HTTP Latency (Via Proxy)"
      result=$(curl -o /dev/null -s -w "%{time_total}" -x "$PROXY" "$LATENCY_DEST")
      echo "Time: ${result}s"
      log_result "latency" "http_proxy" "$result" "$LATENCY_DEST"
    fi
  else
    echo "--> Ping Latency"
    result=$(ping -c 5 "$LATENCY_DEST" | awk -F '/' 'END{ print $(NF-1) }')
    echo "Avg Latency: ${result}ms"
    log_result "latency" "ping" "$result" "$LATENCY_DEST"
  fi
}

run_wget_bandwidth() {
  echo -e "\n[Bandwidth Test - wget]"
  echo "Destination: $WGET_DEST"

  echo "--> Direct Download"
  result=$( (time wget --output-document=/dev/null "$WGET_DEST") 2>&1 | grep real | awk '{print $2}')
  seconds=$(echo "$result" | awk -Fm '{print ($1*60)+$2}')
  echo "Time: ${seconds}s"
  log_result "wget" "direct_time" "$seconds" "$WGET_DEST"

  if [[ -n "$PROXY" ]]; then
    echo "--> Proxy Download"
    result=$( (time wget --output-document=/dev/null -e use_proxy=yes -e http_proxy="http://$PROXY" "$WGET_DEST") 2>&1 | grep real | awk '{print $2}')
    seconds=$(echo "$result" | awk -Fm '{print ($1*60)+$2}')
    echo "Time: ${seconds}s"
    log_result "wget" "proxy_time" "$seconds" "$WGET_DEST"
  fi
}

run_iperf3() {
  echo -e "\n[Bandwidth Test - iperf3]"
  echo "Destination: $IPERF_DEST"

  result=$(iperf3 -c "$IPERF_DEST" 2>/dev/null | grep -A1 "receiver" | grep -Eo '[0-9.]+ Mbits/sec')
  echo "Speed: ${result:-N/A}"
  log_result "iperf3" "direct_speed" "${result:-N/A}" "$IPERF_DEST"
}

echo "=== Running Network Test ==="
echo "Default Destination: $DEST"
[[ -n "$LATENCY_DEST" ]] && echo "Latency Destination: $LATENCY_DEST"
[[ -n "$WGET_DEST" ]] && echo "Wget Destination: $WGET_DEST"
[[ -n "$IPERF_DEST" ]] && echo "iPerf3 Destination: $IPERF_DEST"
[[ -n "$PROXY" ]] && echo "Proxy: $PROXY"
echo "Test Type: $TEST_TYPE"
echo "Results will be logged to $LATENCY_LOG, $WGET_LOG, $IPERF_LOG"
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
  
  # Process all log files to create a summary
  awk -F',' '
    FNR==1 { next }  # Skip headers
    {
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
  ' "$LATENCY_LOG" "$WGET_LOG" "$IPERF_LOG" | sort >> "$summary_file"
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
echo "- Latency test log: $LATENCY_LOG"
echo "- Wget test log: $WGET_LOG"
echo "- iPerf3 test log: $IPERF_LOG"
echo "- Summary report: $SUMMARY_FILE"
echo "- Plots: $PLOT_DIR/*.png"

