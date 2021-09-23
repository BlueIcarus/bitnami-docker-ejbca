#!/bin/bash

# shellcheck disable=SC1091

set -o errexit
set -o nounset
set -o pipefail
#set -o xtrace # Uncomment this line for debugging purposes

# Load libraries
. /opt/bitnami/scripts/libbitnami.sh
. /opt/bitnami/scripts/liblog.sh
. /opt/bitnami/scripts/libejbca.sh

# Load ejbca environment variables
. /opt/bitnami/scripts/ejbca-env.sh

print_welcome_page

if [[ "$*" = *"/opt/bitnami/scripts/ejbca/run.sh"* ]]; then
    info "** Starting ejbca setup **"
    /opt/bitnami/scripts/ejbca/setup.sh
    info "** ejbca setup finished! **"
fi

echo ""
exec "$@"
