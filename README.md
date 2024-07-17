![alt network-testing-bash-script](https://github.com/russellgrapes/bash-ifspeedtest/blob/main/placeholder.png)

# Network Testing Bash Script

A versatile bash script designed for fast comparison of main network parameters across multiple IPs. It is useful when you need to choose a faster or better bandwidth route between your servers around the network.

## Features

- **MTR Tests**: Runs `mtr` tests to measure packet loss and latency.
- **Iperf3 Tests**: Runs `iperf3` tests to measure upload and download speeds.
- **Comparison Results**: Compares all parameters and shows the best result.
- **Logging**: Saves test results to log files with customizable log directory.
- **Flexible Configuration**: Allows customization of test parameters through command-line options.

## Usage

The `ifspeedtest.sh` script offers various command-line options for running network tests:

```bash
./ifspeedtest.sh [options]
```

### Options

- `-i, --ip <IP>`: Specifies the IP to test.
- `--ips <file>`: Specifies the file with IPs to test.
- `--mtr [count]`: Run `mtr` test. Optionally specify the number of pings to send (default: 10).
- `--iperf3 [time]`: Run `iperf3` test. Optionally specify the duration in seconds (default: 10).
- `-I <interface>`: Specifies which interface to use for the test.
- `--log [directory]`: Save log in the specified directory (default: current working directory).
- `-h, --help`: Show this help message and exit.

Global Variables:
- `IPERF3_PARALLEL`: Number of parallel streams to use in iperf3 test (default: 10).

### Examples

```bash
./ifspeedtest.sh -i 10.1.1.1
./ifspeedtest.sh --ips ips.ini --mtr 30 --iperf3 30 --log /home/logs/ -I eth0
```

### ips.ini File

The `ips.ini` file should contain a list of IP addresses, each on a new line. The script will run tests on each IP listed in this file.

Example `ips.ini` file:

```bash
10.1.1.1
10.1.1.2
10.1.1.3
```

## Configuration

The script allows customization of test parameters through global variables and command-line options.

### Global Variables

- `MTR_COUNT`: Default number of pings to send in `mtr` test (default: 10).
- `IPERF3_TIME`: Default duration in seconds for each `iperf3` test (default: 10).
- `IPERF3_PARALLEL`: Number of parallel streams to use in `iperf3` test (default: 10).
- `CONNECT_TIMEOUT`: Timeout in milliseconds for `iperf3` connection attempts (default: 5000).
- `LOG_DIR`: Directory to save log files (default: current working directory).

## Installation

Follow these steps to install and set up the `ifspeedtest.sh` script on your server.

### Install Required Packages

Install the main required packages:

```bash
sudo apt-get install mtr iperf3 libxml2-utils gawk bc
```

Or for CentOS:

```bash
sudo yum install mtr iperf3 libxml2 gawk bc
```

### Download Script

Download the script directly using `curl`:

```bash
curl -O https://raw.githubusercontent.com/russellgrapes/bash-ifspeedtest/main/ifspeedtest.sh
```

### Make the Script Executable

Change the script's permissions to make it executable:

```bash
chmod +x ifspeedtest.sh
```

### Running the Script

Run the script with the desired options:

```bash
./ifspeedtest.sh -i 10.1.1.1
```

The script will check for required dependencies and prompt to install any that are missing.

## Contributing

Contributions are what make the open-source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".

Don't forget to give the project a star! Thanks again!

## License

Distributed under the MIT License. See `LICENSE` for more information.

## Author

I write loops to skip out on life's hoops.

Russell Grapes - [www.grapes.team](https://grapes.team)

Project Link: [https://github.com/russellgrapes/bash-ifspeedtest](https://github.com/russellgrapes/bash-ifspeedtest)
