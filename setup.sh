#!/bin/bash

ARCH=$(arch)

if [[ ! -f /usr/bin/apt ]]; then
 echo "APT was not found. This script is meant for debian machines only. Exiting."
 exit 1
fi

if [[ ${ARCH} == "x86_64" ]]; then
   echo "amd64 architecture confirmed."
elif [[ ${ARCH} == "aarch64" ]]; then
   echo "aarch64 architecture confirmed."
else
   echo "${ARCH} architecture not supported."
fi

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. sudo ./setup.sh"
   exit 1
fi

if [[ ! -d ./chipper ]]; then
   echo "Script is not running in the jank-escape-pod/ directory or chipper folder is missing. Exiting."
   exit 1
fi

echo "Checks have passed!"
echo

function getPackages() {
   if [[ ! -f ./vector-cloud/packagesGotten ]]; then
      echo "Installing required packages (ffmpeg, docker.io, golang, wget, openssl, net-tools)"
      apt update -y
      apt install -y ffmpeg docker.io wget openssl net-tools libsox-dev
      systemctl start docker
      touch ./vector-cloud/packagesGotten
      echo
      echo "Installing golang binary package"
      mkdir golang
      cd golang
      if [[ ${ARCH} == "x86_64" ]]; then
         wget -q --show-progress https://go.dev/dl/go1.18.2.linux-amd64.tar.gz
         rm -rf /usr/local/go && tar -C /usr/local -xzf go1.18.2.linux-amd64.tar.gz
         export PATH=$PATH:/usr/local/go/bin
      elif [[ ${ARCH} == "aarch64" ]]; then
         wget -q --show-progress https://go.dev/dl/go1.18.2.linux-arm64.tar.gz
         rm -rf /usr/local/go && tar -C /usr/local -xzf go1.18.2.linux-arm64.tar.gz
         export PATH=$PATH:/usr/local/go/bin
      fi
      cd ..
      rm -rf golang
   else
      echo "Required packages already gotten."
   fi
   echo
}

function buildCloud() {
   echo
   echo "Building vector-cloud"
   echo
   cd vector-cloud
   make docker-builder
   make vic-cloud
   cd ..
   echo
   echo "./vector-cloud/build/vic-cloud built!"
   echo
}

function buildChipper() {
   echo
   cd chipper
   if [[ ${ARCH} == "aarch64" ]]; then
      touch aarch64
   fi
   ./build.sh
   echo "./chipper/chipper built!"
   echo
   cd ..
}

function getSTT() {
   if [[ ! -f ./stt/completed ]]; then
      echo "Getting STT assets"
      if [[ -d ./stt ]]; then
         rm -rf ./stt
      fi
      mkdir stt
      cd stt
      if [[ ${ARCH} == "x86_64" ]]; then
         wget -q --show-progress https://github.com/coqui-ai/STT/releases/download/v1.3.0/native_client.tflite.Linux.tar.xz
         tar -xf native_client.tflite.Linux.tar.xz
         rm -f ./native_client.tflite.Linux.tar.xz
      elif [[ ${ARCH} == "aarch64" ]]; then
         wget -q --show-progress https://github.com/coqui-ai/STT/releases/download/v1.3.0/native_client.tflite.linux.aarch64.tar.xz
         tar -xf native_client.tflite.linux.aarch64.tar.xz
         rm -f ./native_client.tflite.linux.aarch64.tar.xz
      fi
      echo "Getting STT model..."
      wget -q --show-progress https://coqui.gateway.scarf.sh/english/coqui/v1.0.0-large-vocab/model.tflite
      echo "Getting STT scorer..."
      wget -q --show-progress https://coqui.gateway.scarf.sh/english/coqui/v1.0.0-large-vocab/large_vocabulary.scorer
      echo
      touch completed
      echo "STT assets successfully downloaded!"
      cd ..
   else
      echo "STT assets already there!"
   fi
}

function IPDNSPrompt() {
   read -p "Enter a number (1): " yn
   case $yn in
      "1" ) SANPrefix="IP";;
      "2" ) SANPrefix="DNS";;
      "" ) SANPrefix="IP";;
      * ) echo "Please answer with 1 or 2."; IPDNSPrompt;;
   esac
}

function IPPrompt() {
   read -p "Enter the IP address of this machine (or of the machine you want to use this with): " ipaddress
   if [[ ! -n ${ipaddress} ]]; then
      echo "You must enter an IP address."
      IPPrompt
   fi
   address=${ipaddress}
}

function DNSPrompt() {
   read -p "Enter the domain you would like to use: " dnsurl
   if [[ ! -n ${dnsurl} ]]; then
      echo "You must enter a domain."
      DNSPrompt
   fi
   address=${dnsurl}
}

function generateCerts() {
   echo
   echo "Creating certificates"
   echo
   echo "Would you like to use your IP address or a domain for the Subject Alt Name?"
   echo "1: IP address (recommended)"
   echo "2: Domain"
   IPDNSPrompt
   if [[ ${SANPrefix} == "IP" ]]; then
      IPPrompt
   else
      DNSPrompt
   fi
   rm -rf ./certs
   mkdir certs
   cd certs
   echo ${address} > address
   echo "Creating san config"
   echo "[req]" > san.conf
   echo "default_bits  = 4096" >> san.conf
   echo "default_md = sha256" >> san.conf
   echo "distinguished_name = req_distinguished_name" >> san.conf
   echo "x509_extensions = v3_req" >> san.conf
   echo "prompt = no" >> san.conf
   echo "[req_distinguished_name]" >> san.conf
   echo "C = US" >> san.conf
   echo "ST = VA" >> san.conf
   echo "L = SomeCity" >> san.conf
   echo "O = MyCompany" >> san.conf
   echo "OU = MyDivision" >> san.conf
   echo "CN = ${address}" >> san.conf
   echo "[v3_req]" >> san.conf
   echo "keyUsage = nonRepudiation, digitalSignature, keyEncipherment" >> san.conf
   echo "extendedKeyUsage = serverAuth" >> san.conf
   echo "subjectAltName = @alt_names" >> san.conf
   echo "[alt_names]" >> san.conf
   echo "${SANPrefix}.1 = ${address}" >> san.conf
   echo "Generating key and cert"
   openssl req -x509 -nodes -days 730 -newkey rsa:2048 -keyout cert.key -out cert.crt -config san.conf
   echo
   cd ../vector-cloud
   certCrt=$(cat ../certs/cert.crt)
   echo "package main" > cloud/cert.go
   echo >> cloud/cert.go
   echo 'const awesomeCert = `' >> cloud/cert.go
   cat ../certs/cert.crt >> cloud/cert.go
   echo -n '`' >> cloud/cert.go
   echo "Certificates generated and put into vector-cloud source!"
   cd ..
}

function makeSource() {
   if [[ ! -f ./certs/address ]]; then
      echo "You need to generate certs first!"
      exit 0
   fi
   cd chipper
   rm -f ./source.sh
   read -p "What port would you like to use? (443): " portPrompt
   if [[ -n ${portPrompt} ]]; then
      port=${portPrompt}
   else
      port="443"
   fi
   echo "export DDL_RPC_PORT=${port}" > source.sh
   echo 'export DDL_RPC_TLS_CERTIFICATE=$(cat ../certs/cert.crt)' >> source.sh
   echo 'export DDL_RPC_TLS_KEY=$(cat ../certs/cert.key)' >> source.sh
   echo "DDL_RPC_CLIENT_AUTHENTICATION=NoClientCert" >> source.sh
   cd ..
   echo
   echo "Created source.sh file!"
   echo
   cd certs
   echo "Creating server_config.json for robot"
   echo '{"jdocs": "jdocs.api.anki.com:443", "tms": "token.api.anki.com:443", "chipper": "REPLACEME", "check": "conncheck.global.anki-services.com/ok", "logfiles": "s3://anki-device-logs-prod/victor", "appkey": "oDoa0quieSeir6goowai7f"}' > server_config.json
   address=$(cat address)
   sed -i "s/REPLACEME/${address}:${port}/g" server_config.json
   cd ..
   echo "Created!"
   echo
}

function scpToBot() {
   if [[ ! -n ${keyPath} ]]; then
      echo "To copy vic-cloud and server_config.json to your robot, run this script like this:"
      echo "Usage: sudo ./setup.sh scp <vector's ip> <path/to/ssh-key>"
      echo "Example: sudo ./setup.sh scp 192.168.1.150 /home/wire/id_rsa_Vector-R2D2"
      exit 0
   fi
   if [[ ! -f ${keyPath} ]]; then
      echo "The key that was provided was not found. Exiting."
      exit 0
   fi
   botBuildProp=$(ssh -i ${keyPath} root@${botAddress} "cat /build.prop")
   if [[ ! "${botBuildProp}" == *"ro.build"* ]]; then
      echo "Unable to communicate with robot. Make sure this computer and Vector are on the same network and the IP address is correct. Exiting."
      exit 0
   fi
   ssh -i ${keyPath} root@${botAddress} "mount -o rw,remount / && systemctl stop vic-cloud && mv /anki/data/assets/cozmo_resources/config/server_config.json /anki/data/assets/cozmo_resources/config/server_config.json.bak"
   scp -i ${keyPath} ./vector-cloud/build/vic-cloud root@${botAddress}:/anki/bin/
   scp -i ${keyPath} ./certs/server_config.json root@${botAddress}:/anki/data/assets/cozmo_resources/config/
   ssh -i ${keyPath} root@${botAddress} "chmod +rwx /anki/data/assets/cozmo_resources/config/server_config.json /anki/bin/vic-cloud && systemctl start vic-cloud"
   echo "Everything is now setup! You should be ready to run chipper. Instructions in README.md"
}

function firstPrompt() {
   read -p "Enter a number (1): " yn
   case $yn in
      "1" ) echo; getPackages; getSTT; generateCerts; buildCloud; buildChipper; makeSource; echo "Everything is done! To copy everything needed to your bot, run this script like this:"; echo "Usage: sudo ./setup.sh scp <vector's ip> <path/to/ssh-key>"; echo "Example: sudo ./setup.sh scp 192.168.1.150 /home/wire/id_rsa_Vector-R2D2";;
      "2" ) echo; getPackages; buildCloud;;
      "3" ) echo; getPackages; buildChipper;;
      "4" ) echo; rm -f ./stt/completed; getSTT;;
      "5" ) echo; getPackages; generateCerts; makeSource;;
      "" ) echo; getPackages; getSTT; generateCerts; buildCloud; buildChipper; makeSource; echo "Everything is done! To copy everything needed to your bot, run this script like this:"; echo "Usage: sudo ./setup.sh scp <vector's ip> <path/to/ssh-key>"; echo "Example: sudo ./setup.sh scp 192.168.1.150 /home/wire/id_rsa_Vector-R2D2";;
      * ) echo "Please answer with 1, 2, 3, 4, 5, or just press enter with no input for 1."; firstPrompt;;
   esac
}

if [[ $1 == "scp" ]]; then
   echo "SCPing..."
   botAddress=$2
   keyPath=$3
   scpToBot
   exit 0
fi

echo "What would you like to do?"
echo "1: Full Setup (recommended) (builds vic-cloud and chipper, gets STT stuff, generates certs, creates source.sh file, and creates server_config.json for your bot"
echo "2: Just build vic-cloud"
echo "3: Just build chipper"
echo "4: Just get STT stuff"
echo "5: Just generate certs and create source.sh file"
echo "If you have done everything you have needed, run './setup.sh scp vectorip path/to/key' to copy the new vic-cloud and server config to Vector."
echo
firstPrompt
echo "completed"
