#!/usr/bin/env bash

# Note: run make freebsd-links, make linux-links or make local-links
# before running this test

source generate_certs.sh

PASSED=0
FAILED=0
SKIPPED=0

if [ "$OPENSSLDIR" != "" ]; then
  MY_OPENSSL="$OPENSSLDIR/apps/openssl"
  export LD_LIBRARY_PATH=$OPENSSLDIR:$LD_LIBRARY_PATH
fi

if [ ! $MY_OPENSSL ]; then
# Try to use the system OpenSSL
  MY_OPENSSL=openssl
fi

test_connect() {
  cert_dir=$1
  hash_dir=$2
  log_server=$3
  ca=$4
  port=$5
  expect_fail=$6
  strict=$7
 
  # Continue tests on error
  set +e
  ../client/ct connect --ssl_server="127.0.0.1" --ssl_server_port=$port \
    --ct_server_public_key=$cert_dir/$log_server-key-public.pem \
    --ssl_client_trusted_cert_dir=$hash_dir --logtostderr=true \
    --ssl_client_require_sct=$strict \
    --ssl_client_expect_handshake_failure=$expect_fail

  local retcode=$?
  set -e

  if [ $retcode -eq 0 ]; then
    echo "PASS"
    let PASSED=$PASSED+1
  else
    echo "FAIL"
    let FAILED=$FAILED+1
  fi
}

test_range() {
  ports=$1
  cert_dir=$2
  hash_dir=$3
  log_server=$4
  ca=$5
  conf=$6
  expect_fail=$7
  strict=$8
  apache=$9

  echo "Starting Apache"
  $apache -d `pwd`/$cert_dir -f `pwd`/$conf -k start

  for port in $ports; do
    test_connect $cert_dir $hash_dir $log_server $ca $port $expect_fail $strict
  done

  echo "Stopping Apache"
  $apache -d `pwd`/$cert_dir -f `pwd`/$conf -k stop
  # Wait for Apache to die
  sleep 5
}

# Regression tests against known good/bad certificates
mkdir -p ca-hashes
hash=$($MY_OPENSSL x509 -in testdata/ca-cert.pem -hash -noout)
cp testdata/ca-cert.pem ca-hashes/$hash.0

echo "Testing known good/bad certificate configurations" 
mkdir -p testdata/logs
if [ -f httpd-new ]; then
  test_range "8125 8126 8127 8128 8129" testdata ca-hashes ct-server ca \
    httpd-valid-new.conf false true ./httpd-new

# First check that connection succeeds if we don't require the SCT,
# to isolate the error
 test_range "8125 8126 8127 8128 8129" testdata ca-hashes ct-server ca \
    httpd-invalid-new.conf false false ./httpd-new

test_range "8125 8126 8127 8128 8129" testdata ca-hashes ct-server ca \
    httpd-invalid-new.conf true true ./httpd-new
else
  echo "WARNING: Apache development version not specified, skipping some tests"
  let SKIPPED=$SKIPPED+2
  test_range "8125 8126 8127 8128" testdata ca-hashes ct-server ca \
    httpd-valid.conf false true ./apachectl
  test_range "8125 8126 8127 8128" testdata ca-hashes ct-server ca \
    httpd-invalid.conf false false ./apachectl
  test_range "8125 8126 8127 8128" testdata ca-hashes ct-server ca \
    httpd-invalid.conf true true ./apachectl
fi

rm -rf ca-hashes

# Generate new certs dynamically and repeat the test for valid certs
mkdir -p tmp
# A directory for trusted certs in OpenSSL "hash format"
mkdir -p tmp/ca-hashes

echo "Generating CA certificates in tmp and hashes in tmp/ca"
make_ca_certs `pwd`/tmp `pwd`/tmp/ca-hashes ca $MY_OPENSSL
echo "Generating log server keys in tmp"
make_log_server_keys `pwd`/tmp ct-server

# Start the log server and wait for it to come up
echo "Starting CT server with trusted certs in $hash_dir"
mkdir -p tmp/storage
mkdir -p tmp/storage/certs
mkdir -p tmp/storage/tree

test_ct_server() {
  flags=$@

  ../server/ct-server --port=8124 --key="$cert_dir/$log_server-key.pem" \
      --trusted_cert_dir="$hash_dir" --logtostderr=true $flags &

  server_pid=$!
  sleep 2

  echo "Generating test certificates"
  make_certs `pwd`/tmp `pwd`/tmp/ca-hashes test ca ct-server 8124 false
  # Generate a second set of certs that chain through an intermediate
  make_intermediate_ca_certs `pwd`/tmp intermediate ca
  make_certs `pwd`/tmp `pwd`/tmp/ca-hashes test2 intermediate ct-server 8124 \
      true

  # Stop the log server
  kill -9 $server_pid  
  sleep 2

  echo "Testing valid configurations with new certificates"
  mkdir -p tmp/logs
  if [ -f httpd-new ]; then
      test_range "8125 8126 8127 8128 8129" tmp tmp/ca-hashes ct-server ca \
	  httpd-valid-new.conf 0 true ./httpd-new
  else
      echo "WARNING: Apache development version not specified, skip some tests"
      let SKIPPED=$SKIPPED+1
      test_range "8125 8126 8127 8128" tmp tmp/ca-hashes ct-server ca \
	  httpd-valid.conf 0 true ./apachectl
  fi
}

test_ct_server --sqlite_db=tmp/storage/ct

test_ct_server --cert_dir="tmp/storage/certs"  --tree_dir="tmp/storage/tree" \
    --cert_storage_depth=3 --tree_storage_depth=8

echo "Cleaning up"
rm -rf tmp
if [ $FAILED == 0 ]; then
  rm -rf testdata/logs
fi
echo "PASSED $PASSED tests"
echo "FAILED $FAILED tests"
echo "SKIPPED $SKIPPED tests"