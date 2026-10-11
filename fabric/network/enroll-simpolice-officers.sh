#!/usr/bin/env bash
# Step 6: SimPolice's CA registers and enrolls the demo officers, with their
# role written into the certificate (`:ecert`), so the chaincode can read it
# with getAttributeValue('role'):
#   officer1     role=officer, unit=demo-unit, jc.simulated=true
#   supervisor1  role=supervisor, jc.simulated=true
# Their MSP folders go under organizations/peerOrganizations/
# simpolice.example.com/users/<name>@simpolice.example.com/msp.
#
# Run inside WSL after add-simpolice.sh. Safe to re-run: existing
# registrations are kept and only re-enrolled.
set -eo pipefail

SAMPLES=${FABRIC_SAMPLES:-$HOME/fabric/fabric-samples}
TN=$SAMPLES/test-network
ORG_DIR=$TN/organizations/peerOrganizations/simpolice.example.com
CA_TLS=$TN/addSimPolice/fabric-ca/simpolice/tls-cert.pem
CA_URL=localhost:11054
CA_NAME=ca-simpolice
CERT_NAMES='C=IN,ST=Karnataka,L=Bengaluru,O=SimPolice (SIMULATED)'
export PATH=$SAMPLES/bin:$PATH
# The CA admin enrolled by add-simpolice.sh registers new identities.
export FABRIC_CA_CLIENT_HOME=$ORG_DIR

# name  secret  attributes
OFFICERS=(
  "officer1|officer1pw|role=officer:ecert,unit=demo-unit:ecert,jc.simulated=true:ecert"
  "supervisor1|supervisor1pw|role=supervisor:ecert,jc.simulated=true:ecert"
)

for entry in "${OFFICERS[@]}"; do
  IFS='|' read -r name secret attrs <<<"$entry"

  if fabric-ca-client identity list --id "$name" --caname "$CA_NAME" -u "https://$CA_URL" \
       --tls.certfiles "$CA_TLS" >/dev/null 2>&1; then
    echo "$name: already registered"
  else
    echo "$name: registering"
    fabric-ca-client register --caname "$CA_NAME" --id.name "$name" --id.secret "$secret" \
      --id.type client --id.attrs "$attrs" -u "https://$CA_URL" --tls.certfiles "$CA_TLS"
  fi

  msp=$ORG_DIR/users/$name@simpolice.example.com/msp
  rm -rf "$msp"
  fabric-ca-client enroll -u "https://$name:$secret@$CA_URL" --caname "$CA_NAME" -M "$msp" \
    --tls.certfiles "$CA_TLS" --csr.names "$CERT_NAMES"
  # NodeOUs, so the peer classifies them as clients of SimPoliceMSP.
  cp "$ORG_DIR/msp/config.yaml" "$msp/config.yaml"
  echo "$name: enrolled at $msp"
done
