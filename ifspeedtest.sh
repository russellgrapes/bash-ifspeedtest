#!/bin/bash

#  _________   _________   _________
# |         | |         | |         |
# |   six   | |    2    | |   one   |
# |_________| |_________| |_________|
#     |||         |||         |||
# -----------------------------------
#        ifspeedtest.sh v.2.02
# -----------------------------------

# Network testing script for running mtr and iperf3 tests

# This script provides comprehensive network diagnostics using mtr and iperf3.
# Features include:
# - Testing individual IP addresses or multiple IPs from a file.
# - Specifying network interfaces for targeted testing.
# - Running both mtr and iperf3 tests by default if no specific test is mentioned.
# - Calculating average upload and download speeds from iperf3 results.
# - Detailed logging of test commands and results.
# - Customizable test parameters, such as the number of pings, test duration, and parallel streams.
# - Displaying summary results for best ping, best upload, best download, and best hops when testing multiple IPs.

# Author: https://github.com/russellgrapes/









# Configuration variables
MTR_COUNT=10              # Number of pings to send in mtr test
IPERF3_TIME=10            # Duration in seconds for each iperf3 test
IPERF3_PARALLEL=10        # Number of parallel streams to use in iperf3 test
CONNECT_TIMEOUT=5000      # Timeout in milliseconds for iperf3 connection attempts
LOG_DIR=$(pwd)            # Directory to save log files (current working directory)






# Main code

# Variables to track best results
BEST_PING=""
BEST_PING_IP=""
MIN_HOPS=""
MIN_HOPS_IP=""
BEST_UPLOAD=""
BEST_UPLOAD_IP=""
BEST_DOWNLOAD=""
BEST_DOWNLOAD_IP=""

# Colors for output
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
NC='\033[0m' # No Color

# Function to display help
show_help() {
  local main_iface=$(ip route | grep default | awk '{print $5}')
  echo "
Usage: $0 [options]

Options:
  -i, --ip <IP>          Specifies the IP to test.
  --ips <file>           Specifies the file with IPs to test.
  --mtr [count]          Run mtr test. Optionally specify the number of pings to send (default: $MTR_COUNT).
  --iperf3 [time]        Run iperf3 test. Optionally specify the duration in seconds (default: $IPERF3_TIME).
  -I <interface>         Specifies which interface to use for the test.
  --log [directory]      Save log in the specified directory (default: $LOG_DIR).
  -h, --help             Show this help message and exit.

Global Variables:
  IPERF3_PARALLEL        Number of parallel streams to use in iperf3 test (default: $IPERF3_PARALLEL).

Examples:
  $0 -i 10.1.1.1
  $0 --ips ips.ini --mtr 30 --iperf3 30 --log /home/logs/ -I $main_iface

Example of ips.ini file:
  10.1.1.1
  10.2.2.1
  10.3.3.1
"
}

# Function to check for required tools and propose installation
check_tools() {
  # Define required tools and their corresponding package names for different OSes
  declare -A debian_packages=( ["mtr"]="mtr" ["iperf3"]="iperf3" ["xmllint"]="libxml2-utils" ["awk"]="awk" ["bc"]="bc" )
  declare -A redhat_packages=( ["mtr"]="mtr" ["iperf3"]="iperf3" ["xmllint"]="libxml2" ["awk"]="gawk" ["bc"]="bc" )
  declare -A arch_packages=( ["mtr"]="mtr" ["iperf3"]="iperf3" ["xmllint"]="libxml2" ["awk"]="gawk" ["bc"]="bc" )
  
  # Function to detect OS
  detect_os() {
    if [[ -f /etc/debian_version ]]; then
      echo "debian"
    elif [[ -f /etc/redhat-release ]]; then
      echo "redhat"
    elif [[ -f /etc/arch-release ]]; then
      echo "arch"
    else
      echo "unknown"
    fi
  }
  
  # Function to install packages
  install_packages() {
    local os=$1
    shift
    local packages=("$@")
    
    case $os in
      "debian")
        sudo apt update
        sudo apt install -y "${packages[@]}"
      ;;
      "redhat")
        sudo yum install -y "${packages[@]}"
      ;;
      "arch")
        sudo pacman -Syu --noconfirm "${packages[@]}"
      ;;
      *)
        echo "Unsupported OS. Please install the required packages manually."
        exit 1
      ;;
    esac
  }
  
  # Detect OS
  os=$(detect_os)
  
  # Check for each required tool and prompt to install if missing
  for tool in "${!debian_packages[@]}"; do
    if ! command -v $tool &> /dev/null; then
      echo "$tool is not installed."
      if [[ $os != "unknown" ]]; then
        package_name=""
        case $os in
          "debian")
            package_name=${debian_packages[$tool]}
          ;;
          "redhat")
            package_name=${redhat_packages[$tool]}
          ;;
          "arch")
            package_name=${arch_packages[$tool]}
          ;;
        esac
        read -p "Do you want to install $package_name? (yes/no): " response
        if [[ $response == "yes" ]]; then
          install_packages $os $package_name
        else
          echo "Please install $package_name manually."
          exit 1
        fi
      else
        echo "Please install $tool manually."
        exit 1
      fi
    fi
  done
}

# Function to validate IP or domain and resolve domain to IP
validate_ip_domain() {
  local input=$1

  # Check if input is a valid IPv4 address
  if [[ $input =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    # Validate each octet
    for octet in $(echo $input | tr "." " "); do
      if ((octet < 0 || octet > 255)); then
        echo "Error: Invalid IP address: $input"
        exit 1
      fi
    done
    echo "$input"
    return 0
  fi

  # Check if input is a valid domain name
  if [[ $input =~ ^(([a-zA-Z0-9](-*[a-zA-Z0-9])*)\.)+[a-zA-Z]{2,}$ ]]; then
    # Resolve domain to IP
    resolved_ip=$(dig +short $input | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    if [[ -z $resolved_ip ]]; then
      echo "Error: Unable to resolve domain to IP: $input"
      exit 1
    fi
    echo "$resolved_ip"
    return 0
  fi

  echo "Error: Invalid IP or domain: $input"
  exit 1
}

# Function to show progress spinner with a message
show_spinner() {
  local pid=$1
  local message=$2
  local delay=0.1
  local spinstr='|/-\'
  local temp
  tput civis  # Hide cursor
  
  while ps -p $pid > /dev/null 2>&1; do
    temp=${spinstr#?}
    printf " [%c] %s" "$spinstr" "$message"
    spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    local msg_length=${#message}
    printf "\b\b\b\b\b\b"
    for ((i=0; i<$msg_length; i++)); do
      printf "\b"
    done
  done
  
  printf "\r\033[K"  # Clear the line
  tput cnorm  # Restore cursor
}

# Function to get the IP address of an interface
get_interface_ip() {
  local iface=$1
  ip -4 addr show $iface | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
}

# Function to run mtr test
run_mtr() {
  local ip=$1
  local iface=$2
  if [ -z "$iface" ]; then
    mtr -tb -c $MTR_COUNT -x $ip > mtr_output.xml 2>&1 &
  else
    mtr -tb -c $MTR_COUNT -x -I $iface $ip > mtr_output.xml 2>&1 &
  fi
  local pid=$!
  show_spinner $pid "Running mtr test for $ip..."
  wait $pid
  mtr_output=$(cat mtr_output.xml)
  if [ "$LOG" = true ]; then
    echo "==================================================================================" >> "$log_file"
    if [ -z "$iface" ]; then
      echo "# mtr -tb -c $MTR_COUNT $ip" >> "$log_file"
    else
      echo "# mtr -tb -c $MTR_COUNT -I $iface $ip" >> "$log_file"
    fi
    echo "$mtr_output" >> "$log_file"
  fi
}

# Function to parse mtr XML output
parse_mtr_output() {
  local xml_file=$1
  local tested_ip=$2
  
  best=$(xmllint --xpath "string(//MTR/HUB[last()]/Best)" $xml_file | awk '{if($0=="") print 0; else print $0}' | awk '{$1=$1};1')
  wrst=$(xmllint --xpath "string(//MTR/HUB[last()]/Wrst)" $xml_file | awk '{if($0=="") print 0; else print $0}' | awk '{$1=$1};1')
  avg=$(xmllint --xpath "string(//MTR/HUB[last()]/Avg)" $xml_file | awk '{if($0=="") print 0; else print $0}' | awk '{$1=$1};1')
  hops=$(xmllint --xpath "count(//MTR/HUB)" $xml_file | awk '{if($0=="") print 0; else print $0}' | awk '{$1=$1};1')
  loss=$(xmllint --xpath "string(//MTR/HUB[last()]/Loss)" $xml_file | awk '{if($0=="") print 0; else print $0}' | awk '{$1=$1};1')
  snt=$(xmllint --xpath "string(//MTR/@TESTS)" $xml_file | awk '{if($0=="") print 0; else print $0}' | awk '{$1=$1};1')
  last_hub_ip=$(xmllint --xpath "//HUB[last()]/@HOST" $xml_file | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
  
  # Check if the last hub IP is the tested IP
  if [ "$last_hub_ip" != "$tested_ip" ]; then
    best="ERROR"
    wrst="ERROR"
    avg="ERROR"
    hops="ERROR"
    loss="ERROR"
    snt="0"
    echo "$last_hub_ip"
  fi
  
  printf "${GREEN}Ping:${NC}   ${GREEN}Best:${NC} %s ms ${GREEN}| Wrst:${NC} %s ms ${GREEN}| Avg:${NC} %s${NC} ${GREEN}| Hops:${NC} %s ${GREEN}| Loss:${NC} %s ${GREEN}| Sent:${NC} %s\n" "$best" "$wrst" "$avg" "$hops" "$loss" "$snt"
}

# Function to run iperf3 test
run_iperf3() {
  local ip=$1
  local iface=$2
  local iface_ip
  
  if [ -n "$iface" ]; then
    iface_ip=$(get_interface_ip $iface)
  fi
  
  if [ -z "$iface_ip" ]; then
    iperf3 --connect-timeout $CONNECT_TIMEOUT -c $ip -f m -t $IPERF3_TIME -P $IPERF3_PARALLEL > iperf3_output.txt 2>&1 &
    local pid=$!
    show_spinner $pid "Running iperf3 test (upload) for $ip..."
    wait $pid
    iperf3 --connect-timeout $CONNECT_TIMEOUT -c $ip -f m -t $IPERF3_TIME -P $IPERF3_PARALLEL -R > iperf3_download_output.txt 2>&1 &
    local pid=$!
    show_spinner $pid "Running iperf3 test (download) for $ip..."
    wait $pid
  else
    iperf3 --connect-timeout $CONNECT_TIMEOUT -c $ip -f m -t $IPERF3_TIME -P $IPERF3_PARALLEL -B $iface_ip > iperf3_output.txt 2>&1 &
    local pid=$!
    show_spinner $pid "Running iperf3 test (upload) for $ip on interface $iface..."
    wait $pid
    iperf3 --connect-timeout $CONNECT_TIMEOUT -c $ip -f m -t $IPERF3_TIME -P $IPERF3_PARALLEL -B $iface_ip -R > iperf3_download_output.txt 2>&1 &
    local pid=$!
    show_spinner $pid "Running iperf3 test (download) for $ip on interface $iface..."
    wait $pid
  fi
  
  iperf3_output=$(cat iperf3_output.txt)
  iperf3_download_output=$(cat iperf3_download_output.txt)
  
  # Check for connection errors
  if grep -q "unable to connect to server" iperf3_output.txt; then
    upload_speed="ERROR"
  else
    # Calculate average upload speed
    upload_speeds=$(echo "$iperf3_output" | grep SUM | grep sender | awk '{print $6}')
    upload_speed_avg=$(echo "$upload_speeds" | awk '{sum+=$1; count+=1} END {if(count>0) print sum/count; else print 0}')
    upload_speed="${upload_speed_avg} Mbits/sec"
  fi
  
  if grep -q "unable to connect to server" iperf3_download_output.txt; then
    download_speed="ERROR"
  else
    # Calculate average download speed
    download_speeds=$(echo "$iperf3_download_output" | grep SUM | grep receiver | awk '{print $6}')
    download_speed_avg=$(echo "$download_speeds" | awk '{sum+=$1; count+=1} END {if(count>0) print sum/count; else print 0}')
    download_speed="${download_speed_avg} Mbits/sec"
  fi
  
  if [ "$LOG" = true ]; then
    echo "==================================================================================" >> "$log_file"
    if [ -z "$iface_ip" ]; then
      echo "# iperf3 --connect-timeout $CONNECT_TIMEOUT -c $ip -f m -t $IPERF3_TIME -P $IPERF3_PARALLEL" >> "$log_file"
    else
      echo "# iperf3 --connect-timeout $CONNECT_TIMEOUT -c $ip -f m -t $IPERF3_TIME -P $IPERF3_PARALLEL -B $iface_ip" >> "$log_file"
    fi
    echo "$iperf3_output" >> "$log_file"
    echo "==================================================================================" >> "$log_file"
    if [ -z "$iface_ip" ]; then
      echo "# iperf3 --connect-timeout $CONNECT_TIMEOUT -c $ip -f m -t $IPERF3_TIME -P $IPERF3_PARALLEL -R" >> "$log_file"
    else
      echo "# iperf3 --connect-timeout $CONNECT_TIMEOUT -c $ip -f m -t $IPERF3_TIME -P $IPERF3_PARALLEL -B $iface_ip -R" >> "$log_file"
    fi
    echo "$iperf3_download_output" >> "$log_file"
  fi
  
  # Cleanup temporary files
  rm -f iperf3_output.txt iperf3_download_output.txt
}


# Function to run tests for a single IP
run_tests_for_ip() {
  local ip_or_domain=$1
  local ip=$(validate_ip_domain "$ip_or_domain")
  local iface=$2
  local iface_display=${iface:-default}
  local avg hops upload_speed_avg download_speed_avg
  
  if [ -z "$MTR" ] && [ -z "$IPERF3" ]; then
    MTR=true
    IPERF3=true
  fi
  
  if [ "$MTR" = true ]; then
    run_mtr $ip $iface
  fi
  
  if [ "$IPERF3" = true ]; then
    run_iperf3 $ip $iface
  fi
  
  echo ""
  printf "${GREEN}===============================================================================================\n${NC}"
  printf "${GREEN}IP:${NC}     %s ${GREEN}| Int:${NC} %s\n" "$ip" "$iface_display"
  if [ "$IPERF3" = true ]; then
    printf "${GREEN}Speed:${NC}  ${GREEN}Upload:${NC} %s ${GREEN}| Download:${NC} %s ${GREEN}| For${NC} %d sec ${GREEN}with${NC} %d ${GREEN}parallel streams${NC}\n" "$upload_speed" "$download_speed" "$IPERF3_TIME" "$IPERF3_PARALLEL"
  fi
  if [ "$MTR" = true ]; then
    parse_mtr_output mtr_output.xml $ip
  fi
  printf "${GREEN}===============================================================================================\n${NC}"
  
  # Update best results, ignoring "ERROR" and "0" values
  if [ -n "$avg" ] && [[ "$avg" != "ERROR" && "$avg" != "0" ]] && \
    ( [ -z "$BEST_PING" ] || (( $(echo "$avg < $BEST_PING" | bc -l) )) ); then
      BEST_PING=$avg
      BEST_PING_IP=$ip
    fi
  
  if [ -n "$hops" ] && [[ "$hops" != "ERROR" && "$hops" != "0" ]] && \
    ( [ -z "$MIN_HOPS" ] || (( $hops < $MIN_HOPS )) ); then
      MIN_HOPS=$hops
      MIN_HOPS_IP=$ip
    fi
  
  if [ -n "$upload_speed_avg" ] && [ "$upload_speed_avg" != "0" ] && \
    ( [ -z "$BEST_UPLOAD" ] || (( $(echo "$upload_speed_avg > $BEST_UPLOAD" | bc -l) )) ); then
      BEST_UPLOAD=$upload_speed_avg
      BEST_UPLOAD_IP=$ip
    fi
  
  if [ -n "$download_speed_avg" ] && [ "$download_speed_avg" != "0" ] && \
    ( [ -z "$BEST_DOWNLOAD" ] || (( $(echo "$download_speed_avg > $BEST_DOWNLOAD" | bc -l) )) ); then
      BEST_DOWNLOAD=$download_speed_avg
      BEST_DOWNLOAD_IP=$ip
    fi
  
}

# Function to process IPs from a file
process_ips_from_file() {
  local file=$1
  local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  
  while IFS= read -r ip_or_domain; do
    # Skip empty lines
    if [[ -z "$ip_or_domain" ]]; then
      continue
    fi
    
    # Validate and resolve IP/domain
    ip=$(validate_ip_domain "$ip_or_domain")
    run_tests_for_ip $ip $INTERFACE
  done < "$file"
  
  # Print best results summary
  echo ""
  printf "${GREEN}==================================================\n${NC}"
  if [ -n "$BEST_PING" ]; then
    echo -e "${GREEN}Best Latency:${NC}    $BEST_PING ms	${GREEN}=>${NC} $BEST_PING_IP"
  fi
  if [ -n "$MIN_HOPS" ]; then
    echo -e "${GREEN}Min Hops:${NC}        $MIN_HOPS		${GREEN}=>${NC} $MIN_HOPS_IP"
  fi
  if [ -n "$BEST_UPLOAD" ]; then
    echo -e "${GREEN}Best Upload:${NC}     $BEST_UPLOAD Mbits/sec	${GREEN}=>${NC} $BEST_UPLOAD_IP"
  fi
  if [ -n "$BEST_DOWNLOAD" ]; then
    echo -e "${GREEN}Best Download:${NC}   $BEST_DOWNLOAD Mbits/sec	${GREEN}=>${NC} $BEST_DOWNLOAD_IP"
  fi
  printf "${GREEN}==================================================\n${NC}"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -i|--ip)
      IP=$2
      shift
      shift
    ;;
    --ips)
      IPS_FILE=$2
      shift
      shift
    ;;
    --mtr)
      if [[ "$2" =~ ^[0-9]+$ ]]; then
        MTR_COUNT=$2
        shift
      fi
      MTR=true
      shift
    ;;
    --iperf3)
      if [[ "$2" =~ ^[0-9]+$ ]]; then
        IPERF3_TIME=$2
        shift
      fi
      IPERF3=true
      shift
    ;;
    -I)
      INTERFACE=$2
      shift
      shift
    ;;
    --log)
      if [[ -n "$2" && ! "$2" =~ ^- ]]; then
        LOG_DIR=$2
        shift
      fi
      LOG=true
      shift
    ;;
    -h|--help)
      show_help
      exit 0
    ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
    ;;
  esac
done

# Validate arguments
if [ -z "$IP" ] && [ -z "$IPS_FILE" ]; then
  echo "Error: You must specify either --ip or --ips."
  show_help
  exit 1
fi

# If neither --mtr nor --iperf3 is specified, set both to true
if [ -n "$IP" ] || [ -n "$IPS_FILE" ]; then
  if [ -z "$MTR" ] && [ -z "$IPERF3" ]; then
    MTR=true
    IPERF3=true
  fi
fi

# Check for required tools
check_tools

# Prepare log file
if [ "$LOG" = true ]; then
  timestamp=$(date +%Y%m%d-%H%M%S)
  log_file="$LOG_DIR/log-$(basename "$0")-$timestamp.txt"
  echo "$0 test at $timestamp" > "$log_file"
fi

echo ""

# Check if testing a single IP or multiple IPs from a file
if [ -n "$IP" ]; then
  ip=$(validate_ip_domain "$IP")
  if [[ $? -ne 0 ]]; then
    echo "$ip"
    exit 1
  fi
  echo "Tests for IP: $ip"
elif [ -n "$IPS_FILE" ]; then
  if [ ! -f "$IPS_FILE" ]; then
    echo "Error: IPs file '$IPS_FILE' not found."
    exit 1
  fi
  echo "Tests for IPs:"
  while IFS= read -r ip_or_domain; do
    # Skip empty lines
    if [[ -z "$ip_or_domain" ]]; then
      continue
    fi
    # Validate and resolve IP/domain
    ip=$(validate_ip_domain "$ip_or_domain")
    if [[ $? -ne 0 ]]; then
      echo "$ip"
      exit 1
    fi
    echo "  - $ip"
  done < "$IPS_FILE"
  echo ""
fi

# Run tests
if [ -n "$IP" ]; then
  run_tests_for_ip $ip $INTERFACE
elif [ -n "$IPS_FILE" ]; then
  if [ ! -f "$IPS_FILE" ]; then
    echo "Error: IPs file '$IPS_FILE' not found."
    exit 1
  fi
  process_ips_from_file $IPS_FILE
fi

# Cleanup mtr temporary file
rm -f mtr_output.xml

echo ""
echo "Tests completed."
echo ""
