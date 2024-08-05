#!/bin/bash

echo "Setting up server environment..."

set -e  # Exit immediately if a command exits with a non-zero status

# Define common directories
COMMON_DIR="$HOME/Concierge-VAP/common"
DDS_DIR="$HOME/dds-zharfanf"
VAP_DIR="$HOME/VAP-Concierge"
RAMDISK_DIR="/tmp/ramdisk"

# Function to install required packages
install_packages() {
    local packages=("$@")
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            echo "Installing missing command: $pkg"
            sudo apt-get install -y "$pkg"
        else
            echo "$pkg is already installed."
        fi
    done
}

# Update and install essential packages
echo "Updating package lists and installing essentials..."
sudo apt-get update -y
install_packages iperf3 ffmpeg unzip wget

# Install yq separately since it might not be available in default repos
if ! command -v yq &>/dev/null; then
    echo "Installing yq..."
    sudo wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq
    sudo chmod +x /usr/bin/yq
else
    echo "yq is already installed."
fi

# Miniconda Installation
if [[ ! -d "$HOME/miniconda3" ]]; then
    echo "Installing Miniconda..."
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-py310_23.3.1-0-Linux-x86_64.sh
    bash Miniconda3-py310_23.3.1-0-Linux-x86_64.sh -b -p "$HOME/miniconda3"
    rm Miniconda3-py310_23.3.1-0-Linux-x86_64.sh
fi

# Initialize conda
eval "$($HOME/miniconda3/bin/conda shell.bash hook)"

# Clone DDS repository
if [[ ! -d "$DDS_DIR" ]]; then
    echo "Cloning DDS repository..."
    git clone https://github.com/zharfanf/dds-zharfanf.git "$DDS_DIR"
else
    echo "DDS repository already cloned."
fi

pushd "$DDS_DIR" > /dev/null
git checkout edge

# Update Conda environment
yq -i '(.dependencies[] | select(. == "tensorflow-gpu=1.14")) = "tensorflow=1.14"' conda_environment_configuration.yml

if conda env list | grep 'dds'; then
    echo "Environment 'dds' already exists. Updating the environment."
    conda env update -f conda_environment_configuration.yml --name dds
else
    echo "Creating new 'dds' environment."
    conda env create -f conda_environment_configuration.yml
fi

conda activate dds

# Ensure Python packages are installed within the Conda environment
python_packages=(gdown pandas matplotlib grpcio grpcio-tools jupyter)
for package in "${python_packages[@]}"; do
    if ! pip show "$package" &>/dev/null; then
        echo "Installing Python package in Conda environment: $package"
        pip install "$package"
    else
        echo "Python package $package is already installed in Conda environment."
    fi
done
popd > /dev/null

# Download Common Data
mkdir -p "$COMMON_DIR"
pushd "$COMMON_DIR" > /dev/null

if [ ! -f "data-set-dds.zip" ]; then
    echo "Downloading data-set-dds.zip..."
    gdown --id 1_dReQ4jiPCtAQvHZSN56MKyGr5dV1MfR
else
    echo "data-set-dds.zip exists."
fi

if [ ! -f "frozen_inference_graph.pb" ]; then
    echo "Downloading frozen_inference_graph.pb..."
    wget -q http://people.cs.uchicago.edu/~kuntai/frozen_inference_graph.pb
else
    echo "frozen_inference_graph.pb exists."
fi
popd > /dev/null

# Prepare DDS Data
pushd "$DDS_DIR" > /dev/null

echo "Unzipping data-set-dds.zip..."
unzip -oq "$COMMON_DIR/data-set-dds.zip" -d .

if [ ! -d "data-set-cpy" ]; then
    echo "Unzip process failed: data-set-cpy does not exist."
    exit 1
fi

rm -rf data-set
mv data-set-cpy data-set

cp -r "$COMMON_DIR/frozen_inference_graph.pb" .
cp -r frozen_inference_graph.pb ./workspace
popd > /dev/null

# Clone and Prepare VAP Concierge
if [[ ! -d "$VAP_DIR" ]]; then
    echo "Cloning VAP Concierge repository..."
    git clone https://github.com/Kyukirel/VAP-Concierge.git "$VAP_DIR"
else
    echo "VAP Concierge repository already cloned."
fi

pushd "$VAP_DIR" > /dev/null
git checkout vap-zharfanf
popd > /dev/null

# Copy necessary files to AWStream and Adaptive directories
ADAPTIVE_DIR="$VAP_DIR/src/app/dds-adaptive"
AWSTREAM_DIR="$VAP_DIR/src/app/awstream-adaptive"

for dir in "$ADAPTIVE_DIR" "$AWSTREAM_DIR"; do
    if [[ -d "$dir" ]]; then
        echo "Copying frozen inference graph to $dir..."
        cp -r "$COMMON_DIR/frozen_inference_graph.pb" "$dir"
    fi
done

# Setup RAM Disk
setup_ramdisk() {
    if mountpoint -q "$RAMDISK_DIR"; then
        echo "$RAMDISK_DIR is already mounted. Unmounting now."
        sudo umount "$RAMDISK_DIR"
    fi

    if [ ! -d "$RAMDISK_DIR" ]; then
        echo "Creating $RAMDISK_DIR directory."
        sudo mkdir "$RAMDISK_DIR"
    fi

    echo "$RAMDISK_DIR exists. Clearing its contents."
    sudo rm -rf "$RAMDISK_DIR"/*

    sudo chmod 777 "$RAMDISK_DIR"
    sudo mount -t tmpfs -o size=80g myramdisk "$RAMDISK_DIR"
    echo "Ramdisk mounted."
}

setup_ramdisk

# Move VAP Concierge to RAM Disk
mv "$VAP_DIR" "$RAMDISK_DIR/"

# Update .bashrc
source ~/.bashrc

echo "Setup completed successfully!"
