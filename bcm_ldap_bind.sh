#!/bin/bash
#
# BCM LDAP Bind Credentials Configuration Script
# Based on: https://kb.brightcomputing.com/knowledge-base/3rd-party-ldap-client-with-bind-credentials/
#
# This script automates the configuration of LDAP bind authentication using
# SASL EXTERNAL mechanism for both head nodes and compute node software images.
#
# Usage:
#   bcm_ldap_bind.sh --discovery    Test discovery of head nodes and software images
#   bcm_ldap_bind.sh --dry-run      Preview what changes would be made
#   bcm_ldap_bind.sh --write        Apply the configuration changes
#   bcm_ldap_bind.sh --validate     Validate LDAP is working correctly
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script mode
MODE=""

# Parse command line arguments
usage() {
    echo "Usage: $0 <MODE>"
    echo ""
    echo "Modes:"
    echo "  --discovery         Test discovery of head nodes, software images, and compute nodes"
    echo "  --dry-run           Preview what changes would be made without modifying anything"
    echo "  --write             Apply the LDAP bind credentials configuration"
    echo "  --validate          Validate that LDAP and bind authentication are working correctly"
    echo "  --rollback          Undo all changes made by --write mode and restore from backups"
    echo "  --rollback-validate Verify system is in original state (before --write changes)"
    echo ""
    echo "Examples:"
    echo "  $0 --discovery         # Test the discovery logic"
    echo "  $0 --dry-run           # See what would be changed"
    echo "  sudo $0 --write        # Apply the changes (requires root)"
    echo "  sudo $0 --validate     # Validate LDAP is working (requires root)"
    echo "  sudo $0 --rollback     # Undo all changes (requires root)"
    echo "  $0 --rollback-validate # Verify system is in original/rolled-back state"
    echo ""
    exit 1
}

if [[ $# -ne 1 ]]; then
    usage
fi

case "$1" in
    --discovery)
        MODE="discovery"
        ;;
    --dry-run)
        MODE="dryrun"
        ;;
    --write)
        MODE="write"
        ;;
    --validate)
        MODE="validate"
        ;;
    --rollback)
        MODE="rollback"
        ;;
    --rollback-validate)
        MODE="rollback-validate"
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "Error: Unknown option: $1"
        echo ""
        usage
        ;;
esac

# Logging functions (output to stderr to avoid interfering with command substitution)
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_dryrun() {
    echo -e "${CYAN}[DRY-RUN]${NC} $1" >&2
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1" >&2
}

# ============================================================================
# Common Functions
# ============================================================================

# Function to discover head nodes
discover_head_nodes() {
    # cmsh output format: Type Hostname MAC Category IP Network Status
    # We want lines where first field is "HeadNode" and extract the second field (Hostname)
    local head_nodes=$(cmsh -c "device list" | awk '$1 == "HeadNode" { print $2 }')
    
    if [[ -z "$head_nodes" ]]; then
        log_error "No head nodes found!"
        exit 1
    fi
    
    echo "$head_nodes"
}

# Function to get software image paths
get_software_image_paths() {
    # cmsh output format: Name Path KernelVersion Nodes
    # We want the second field (Path)
    local image_paths=$(cmsh -c "softwareimage;list" | awk 'NF >= 2 { print $2 }')
    
    if [[ -z "$image_paths" ]]; then
        log_warn "No software images found!" >&2
    fi
    
    echo "$image_paths"
}

# Function to update openldap ldap.conf with SASL external authentication
update_ldap_conf() {
    local conf_file="$1"
    local actual_file="$conf_file"
    
    # If it's a symlink, resolve to the actual file
    if [[ -L "$conf_file" ]]; then
        # Check if this is within a software image path
        if [[ "$conf_file" =~ ^/cm/images/[^/]+ ]]; then
            # In an image: resolve symlink relative to image root
            local link_target=$(readlink "$conf_file")
            if [[ "$link_target" == /* ]]; then
                # Absolute symlink: prepend image root
                local image_root=$(echo "$conf_file" | sed 's|\(/cm/images/[^/]*\)/.*|\1|')
                actual_file="${image_root}${link_target}"
            else
                # Relative symlink: resolve relative to symlink's directory
                actual_file="$(dirname "$conf_file")/$link_target"
            fi
            log_info "  $conf_file is a symlink, updating actual file: $actual_file"
        else
            # Not in an image: use standard resolution
            actual_file=$(readlink -f "$conf_file")
            log_info "  $conf_file is a symlink, updating actual file: $actual_file"
        fi
    fi
    
    if [[ ! -f "$actual_file" ]]; then
        log_warn "File not found: $actual_file - skipping"
        return 1
    fi
    
    if grep -q "^SASL_MECH external" "$actual_file" 2>/dev/null; then
        log_info "SASL_MECH external already present in $actual_file"
        return 0
    else
        log_info "Adding 'SASL_MECH external' to $actual_file"
        # Create backup only if one doesn't exist (preserve original state)
        if ! ls "${actual_file}.backup."* 1> /dev/null 2>&1; then
            cp "$actual_file" "${actual_file}.backup.$(date +%Y%m%d_%H%M%S)"
            log_info "  Created backup of original file"
        else
            log_info "  Backup already exists, preserving original"
        fi
        # Add configuration
        echo "" >> "$actual_file"
        echo "# Force external authentication by default (added by bcm_ldap_bind.sh)" >> "$actual_file"
        echo "SASL_MECH external" >> "$actual_file"
        return 0
    fi
}

# Function to update nslcd.conf with SASL external authentication
update_nslcd_conf() {
    local conf_file="$1"
    
    if [[ ! -f "$conf_file" ]]; then
        log_warn "File not found: $conf_file - skipping"
        return 1
    fi
    
    if grep -q "^sasl_mech external" "$conf_file" 2>/dev/null; then
        log_info "sasl_mech external already present in $conf_file"
        return 0
    else
        log_info "Adding 'sasl_mech external' to $conf_file"
        # Create backup only if one doesn't exist (preserve original state)
        if ! ls "${conf_file}.backup."* 1> /dev/null 2>&1; then
            cp "$conf_file" "${conf_file}.backup.$(date +%Y%m%d_%H%M%S)"
            log_info "  Created backup of original file"
        else
            log_info "  Backup already exists, preserving original"
        fi
        # Add configuration
        echo "" >> "$conf_file"
        echo "# Use certificate as auth (added by bcm_ldap_bind.sh)" >> "$conf_file"
        echo "sasl_mech external" >> "$conf_file"
        return 0
    fi
}

# Function to check if ldap.conf needs updating (for dry-run/discovery)
check_ldap_conf() {
    local conf_file="$1"
    
    if [[ ! -f "$conf_file" ]]; then
        log_warn "File not found: $conf_file"
        return 1
    fi
    
    if grep -q "^SASL_MECH external" "$conf_file" 2>/dev/null; then
        log_info "✓ $conf_file already has 'SASL_MECH external'"
        return 0
    else
        if [[ "$MODE" == "dryrun" ]]; then
            log_dryrun "Would add 'SASL_MECH external' to $conf_file"
            log_dryrun "  Would create backup: ${conf_file}.backup.<timestamp>"
        fi
        return 0
    fi
}

# Function to check if nslcd.conf needs updating (for dry-run/discovery)
check_nslcd_conf() {
    local conf_file="$1"
    
    if [[ ! -f "$conf_file" ]]; then
        log_warn "File not found: $conf_file"
        return 1
    fi
    
    if grep -q "^sasl_mech external" "$conf_file" 2>/dev/null; then
        log_info "✓ $conf_file already has 'sasl_mech external'"
        return 0
    else
        if [[ "$MODE" == "dryrun" ]]; then
            log_dryrun "Would add 'sasl_mech external' to $conf_file"
            log_dryrun "  Would create backup: ${conf_file}.backup.<timestamp>"
        fi
        return 0
    fi
}

# ============================================================================
# DISCOVERY MODE
# ============================================================================

if [[ "$MODE" == "discovery" ]]; then
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          DISCOVERY MODE - Testing Discovery Logic${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_test "Testing Head Node Discovery"
    echo ""
    echo "Running: cmsh -c \"device list\""
    echo ""
    cmsh -c "device list"
    echo ""
    log_info "Extracted head nodes:"
    head_nodes=$(discover_head_nodes)
    
    if [[ -z "$head_nodes" ]]; then
        log_warn "No head nodes found!"
    else
        echo "$head_nodes" | while read -r node; do
            echo "  - $node"
        done
    fi
    
    echo ""
    log_test "Testing Software Image Discovery"
    echo ""
    echo "Running: cmsh -c \"softwareimage;list\""
    echo ""
    cmsh -c "softwareimage;list"
    echo ""
    log_info "Extracted image paths:"
    
    image_paths=$(get_software_image_paths)
    
    if [[ -z "$image_paths" ]]; then
        log_warn "No software images found!"
    else
        echo "$image_paths" | while read -r path; do
            if [[ -n "$path" ]]; then
                echo "  - $path"
                nslcd_path="${path}/etc/nslcd.conf"
                if [[ -f "$nslcd_path" ]]; then
                    echo -e "    ${GREEN}✓${NC} nslcd.conf exists"
                else
                    echo -e "    ${YELLOW}✗${NC} nslcd.conf not found"
                fi
            fi
        done
    fi
    
    echo ""
    log_test "Testing Compute Node Discovery"
    echo ""
    
    compute_nodes=$(cmsh -c "device list" | awk '$1 != "HeadNode" && NF >= 2 { print $2 }')
    
    if [[ -n "$compute_nodes" ]]; then
        node_count=$(echo "$compute_nodes" | wc -w)
        log_info "Found $node_count compute node(s):"
        echo "$compute_nodes" | tr ' ' '\n' | while read -r node; do
            echo "  - $node"
        done
        
        up_nodes=$(cmsh -c "device status" | grep -E "\[\s*UP\s*\]" | awk '{print $1}' | grep -v "HeadNode")
        
        if [[ -n "$up_nodes" ]]; then
            up_count=$(echo "$up_nodes" | wc -w)
            log_info "Of those, $up_count are currently UP"
        else
            log_info "No compute nodes currently UP"
        fi
    else
        log_info "No compute nodes found"
    fi
    
    echo ""
    log_test "Testing SSSD Detection"
    echo ""
    
    if systemctl cat sssd.service >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} SSSD service file found"
        if systemctl is-active --quiet sssd 2>/dev/null; then
            echo -e "${GREEN}✓${NC} SSSD is active"
        elif systemctl is-enabled --quiet sssd 2>/dev/null; then
            echo -e "${YELLOW}○${NC} SSSD is enabled but not active"
        else
            echo -e "${YELLOW}○${NC} SSSD is installed but not enabled/active"
        fi
        
        if [[ -f "/etc/sssd/sssd.conf" ]]; then
            echo -e "${GREEN}✓${NC} /etc/sssd/sssd.conf exists"
        else
            echo -e "${YELLOW}✗${NC} /etc/sssd/sssd.conf not found"
        fi
    else
        echo -e "${YELLOW}○${NC} SSSD is not installed"
    fi
    
    echo ""
    log_test "Testing File Existence"
    echo ""
    
    files_to_check=(
        "/etc/openldap/ldap.conf"
        "/etc/nslcd.conf"
        "/cm/local/apps/openldap/etc/slapd.conf"
    )
    
    for file in "${files_to_check[@]}"; do
        if [[ -f "$file" ]]; then
            echo -e "${GREEN}✓${NC} $file exists"
        else
            echo -e "${YELLOW}✗${NC} $file not found"
        fi
    done
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    log_test "Discovery Test Complete"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "This test verified the discovery logic without making any changes."
    echo "Next steps:"
    echo "  1. Run dry-run mode: $0 --dry-run"
    echo "  2. Apply changes:    sudo $0 --write"
    
    exit 0
fi

# ============================================================================
# DRY-RUN MODE
# ============================================================================

if [[ "$MODE" == "dryrun" ]]; then
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          DRY-RUN MODE - No changes will be made${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_info "Starting LDAP bind credentials configuration analysis..."
    echo ""
    
    # Check SASL2 Support
    log_info "Step 0: Checking SASL2 support..."
    
    SLAPD_PATH="/cm/local/apps/openldap/sbin/slapd"
    
    if [[ ! -f "$SLAPD_PATH" ]]; then
        log_warn "slapd binary not found at $SLAPD_PATH"
    else
        if ldd "$SLAPD_PATH" | grep -q "libsasl2"; then
            log_info "✓ SASL2 support detected in slapd"
        else
            log_error "✗ SASL2 SUPPORT NOT FOUND"
            log_error "The write mode would FAIL at this point and refuse to continue."
            log_error "SASL2 support is required for bind authentication."
            exit 1
        fi
    fi
    
    echo ""
    log_info "Step 1: Analyzing OpenLDAP client (ldap.conf) on head nodes"
    
    if [[ -f "/etc/openldap/ldap.conf" ]]; then
        check_ldap_conf "/etc/openldap/ldap.conf"
    else
        log_warn "/etc/openldap/ldap.conf not found on head node"
    fi
    
    echo ""
    log_info "Step 2: Analyzing nslcd.conf on head nodes"
    head_nodes=$(discover_head_nodes)
    
    for node in $head_nodes; do
        log_info "Checking head node: $node"
        
        if [[ -f "/etc/nslcd.conf" ]]; then
            check_nslcd_conf "/etc/nslcd.conf"
            
            if systemctl cat nslcd.service >/dev/null 2>&1; then
                log_dryrun "  Would restart nslcd service"
            fi
        else
            log_warn "  /etc/nslcd.conf not found on head node"
        fi
    done
    
    echo ""
    log_info "Step 3: Analyzing OpenLDAP and nslcd in software images"
    image_paths=$(get_software_image_paths)
    
    if [[ -n "$image_paths" ]]; then
        while IFS= read -r image_path; do
            if [[ -n "$image_path" ]]; then
                log_info "Checking software image: $image_path"
                
                image_ldap_conf="${image_path}/etc/openldap/ldap.conf"
                check_ldap_conf "$image_ldap_conf"
                
                image_nslcd_conf="${image_path}/etc/nslcd.conf"
                check_nslcd_conf "$image_nslcd_conf"
            fi
        done <<< "$image_paths"
    else
        log_warn "No software images to check"
    fi
    
    echo ""
    log_info "Step 4: Analyzing compute node update requirements"
    
    compute_nodes=$(cmsh -c "device list" | awk '$1 != "HeadNode" && NF >= 2 { print $2 }')
    
    if [[ -n "$compute_nodes" ]]; then
        node_count=$(echo "$compute_nodes" | wc -w)
        log_info "Found $node_count compute node(s)"
        
        up_nodes=$(cmsh -c "device status" | grep -E "\[\s*UP\s*\]" | awk '{print $1}' | grep -v "HeadNode")
        
        if [[ -n "$up_nodes" ]]; then
            up_count=$(echo "$up_nodes" | wc -w)
            log_dryrun "Would run imageupdate on $up_count running compute node(s)"
            log_dryrun "  Command: cmsh -c \"device; imageupdate -t physicalnode -s UP -w --wait\""
            log_dryrun "Would restart nslcd on compute nodes"
            log_dryrun "  Command: cmsh -c \"device; foreach -t physicalnode -s UP * (pexec systemctl restart nslcd)\""
        else
            log_info "No compute nodes currently UP"
            log_info "Changes will be applied when nodes boot"
        fi
    else
        log_info "No compute nodes found"
    fi
    
    echo ""
    log_info "Step 5: Analyzing SSSD configuration"
    
    if systemctl cat sssd.service >/dev/null 2>&1; then
        if systemctl is-active --quiet sssd 2>/dev/null || systemctl is-enabled --quiet sssd 2>/dev/null; then
            sssd_conf="/etc/sssd/sssd.conf"
            
            if [[ -f "$sssd_conf" ]]; then
                log_info "SSSD detected at $sssd_conf"
                
                if grep -q "ldap_uri" "$sssd_conf"; then
                    if grep -q "^[[:space:]]*ldap_sasl_mech[[:space:]]*=" "$sssd_conf"; then
                        log_info "✓ ldap_sasl_mech already present in $sssd_conf"
                    else
                        log_dryrun "Would add 'ldap_sasl_mech = EXTERNAL' to $sssd_conf"
                        log_dryrun "  Would create backup: ${sssd_conf}.backup.<timestamp>"
                        log_dryrun "  Would restart sssd service"
                    fi
                else
                    log_warn "ldap_uri not found in $sssd_conf; would skip SSSD SASL configuration"
                fi
            else
                log_warn "SSSD is installed but $sssd_conf not found"
            fi
        else
            log_info "SSSD service is not active or enabled"
        fi
    else
        log_info "SSSD is not installed"
    fi
    
    echo ""
    log_info "Step 6: Analyzing slapd.conf for bind authentication"
    
    slapd_conf="/cm/local/apps/openldap/etc/slapd.conf"
    
    if [[ -f "$slapd_conf" ]]; then
        log_info "Found $slapd_conf"
        
        if grep -q "^TLSVerifyClient" "$slapd_conf"; then
            if grep -q "^TLSVerifyClient try" "$slapd_conf"; then
                log_info "✓ TLSVerifyClient already set to 'try'"
            else
                current_value=$(grep "^TLSVerifyClient" "$slapd_conf" | awk '{print $2}')
                log_dryrun "Would update TLSVerifyClient from '$current_value' to 'try'"
            fi
        else
            log_dryrun "Would add 'TLSVerifyClient try' to slapd.conf"
        fi
        
        if grep -q "^require authc" "$slapd_conf"; then
            log_info "✓ 'require authc' already present"
        else
            log_dryrun "Would add 'require authc' to slapd.conf"
        fi
        
        log_dryrun "  Would create backup: ${slapd_conf}.backup.<timestamp>"
        
        if systemctl cat slapd.service >/dev/null 2>&1; then
            log_dryrun "  Would restart slapd service"
        fi
    else
        log_warn "slapd.conf not found at $slapd_conf"
    fi
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                      Summary${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    log_info "Dry-run analysis complete!"
    echo ""
    log_info "To apply these changes, run:"
    echo "  ${GREEN}sudo $0 --write${NC}"
    echo ""
    log_info "The write mode will:"
    log_info "  • Validate SASL2 support (will abort if not present)"
    log_info "  • Create timestamped backups of all modified files"
    log_info "  • Add SASL EXTERNAL authentication to ldap.conf files"
    log_info "  • Add SASL EXTERNAL authentication to nslcd.conf files"
    log_info "  • Push changes to running compute nodes via imageupdate"
    log_info "  • Restart nslcd on compute nodes"
    log_info "  • Update SSSD configuration if applicable"
    log_info "  • Configure slapd for bind authentication"
    log_info "  • Restart affected services"
    echo ""
    
    exit 0
fi

# ============================================================================
# VALIDATE MODE - Test LDAP and Bind Authentication
# ============================================================================

if [[ "$MODE" == "validate" ]]; then
    # Ensure the script is run as root
    if [[ $EUID -ne 0 ]]; then
       log_error "Validate mode must be run as root."
       log_error "Please run: sudo $0 --validate"
       exit 1
    fi
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          VALIDATE MODE - Testing LDAP Configuration${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_info "Starting LDAP validation tests..."
    echo ""
    
    VALIDATION_FAILED=0
    
    # ============================================================================
    # TEST 1: Validate LDAP on Head Nodes
    # ============================================================================
    log_info "Test 1: Validating LDAP on head nodes"
    echo ""
    
    head_nodes=$(discover_head_nodes)
    current_hostname=$(hostname -s)
    
    # Temporarily disable errexit to allow loop to continue on failures
    set +e
    
    for node in $head_nodes; do
        log_info "Testing head node: $node"
        
        # Test nslcd service
        ssh -n "$node" "systemctl is-active --quiet nslcd 2>/dev/null" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            log_info "  ✓ nslcd service is running"
        else
            log_error "  ✗ nslcd service is not running"
            VALIDATION_FAILED=1
        fi
        
        # Test LDAP operations (locally for current node, via SSH for remote head node)
        if [[ "$node" == "$current_hostname" ]]; then
            getent passwd cmsupport >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                log_info "  ✓ User lookup via nslcd works (getent passwd)"
            else
                log_error "  ✗ User lookup via nslcd failed"
                VALIDATION_FAILED=1
            fi
            ldapsearch uid=cmsupport >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                log_info "  ✓ Certificate-based LDAP search works (SASL EXTERNAL)"
            else
                log_error "  ✗ Certificate-based LDAP search failed"
                VALIDATION_FAILED=1
            fi
        else
            ssh -n "$node" "getent passwd cmsupport >/dev/null 2>&1" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                log_info "  ✓ User lookup via nslcd works (getent passwd)"
            else
                log_error "  ✗ User lookup via nslcd failed"
                VALIDATION_FAILED=1
            fi
            ssh -n "$node" "ldapsearch uid=cmsupport >/dev/null 2>&1" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                log_info "  ✓ Certificate-based LDAP search works (SASL EXTERNAL)"
            else
                log_error "  ✗ Certificate-based LDAP search failed"
                VALIDATION_FAILED=1
            fi
        fi
        
        echo ""
    done
    
    # Re-enable errexit
    set -e
    
    # ============================================================================
    # TEST 2: Validate LDAP on All UP Compute Nodes
    # ============================================================================
    log_info "Test 2: Validating LDAP on compute nodes"
    echo ""
    
    # Discover compute nodes that are UP
    compute_nodes=$(cmsh -c "device list" | awk '$1 != "HeadNode" && NF >= 2 { print $2 }')
    
    if [[ -n "$compute_nodes" ]]; then
        up_nodes=$(cmsh -c "device status" | grep -E "\[\s*UP\s*\]" | awk '{print $1}')
        # Filter out head nodes explicitly
        filtered_up_nodes=""
        while IFS= read -r n; do
            [[ -z "$n" ]] && continue
            skip=0
            for hn in $head_nodes; do
                if [[ "$n" == "$hn" ]]; then
                    skip=1
                    break
                fi
            done
            [[ $skip -eq 0 ]] && filtered_up_nodes+="$n"$'\n'
        done <<< "$up_nodes"
        
        if [[ -n "$filtered_up_nodes" ]]; then
            # Count nodes to test
            node_count=$(echo "$filtered_up_nodes" | wc -l)
            log_info "Found $node_count UP compute node(s) to test"
            echo ""
            
            # Temporarily disable errexit to allow loop to continue on failures
            set +e
            
            while IFS= read -r node; do
                if [[ -n "$node" ]]; then
                    log_info "Testing node: $node"
                    
                    # Test nslcd service on node
                    ssh -n "$node" "systemctl is-active --quiet nslcd 2>/dev/null" 2>/dev/null
                    if [[ $? -eq 0 ]]; then
                        log_info "  ✓ nslcd service is running"
                    else
                        log_error "  ✗ nslcd service is not running"
                        VALIDATION_FAILED=1
                    fi
                    
                    # Test getent on node (this uses nslcd with certificate auth)
                    ssh -n "$node" "getent passwd cmsupport >/dev/null 2>&1" 2>/dev/null
                    if [[ $? -eq 0 ]]; then
                        log_info "  ✓ User lookup via nslcd works (certificate-based)"
                    else
                        log_error "  ✗ User lookup via nslcd failed"
                        VALIDATION_FAILED=1
                    fi
                    
                    # Verify nslcd is configured with sasl_mech external
                    ssh -n "$node" "grep -q '^sasl_mech external' /etc/nslcd.conf 2>/dev/null" 2>/dev/null
                    if [[ $? -eq 0 ]]; then
                        log_info "  ✓ nslcd.conf has 'sasl_mech external' configured"
                    else
                        log_error "  ✗ nslcd.conf missing 'sasl_mech external'"
                        VALIDATION_FAILED=1
                    fi
                    
                    echo ""
                fi
            done <<< "$filtered_up_nodes"
            
            # Re-enable errexit
            set -e
        else
            log_warn "No compute nodes are currently UP - skipping node tests"
        fi
    else
        log_info "No compute nodes found in cluster"
    fi
    
    # ============================================================================
    # TEST 3: Validate Bind Credentials Authentication
    # ============================================================================
    echo ""
    log_info "Test 3: Validating bind credentials authentication"
    echo ""
    
    TEST_USER="bind-test-user"
    TEST_PASS="testpass"
    
    log_info "Creating temporary test user: $TEST_USER"
    
    # Create test user
    if cmsh -c "user; add $TEST_USER; set password $TEST_PASS; commit" >/dev/null 2>&1; then
        log_info "✓ Test user created successfully"
        
        # Wait a moment for LDAP to sync
        sleep 2
        
        # Test bind authentication with ldapsearch
        log_info "Testing bind authentication with ldapsearch..."
        
        if ldapsearch -D "uid=$TEST_USER,dc=cm,dc=cluster" -w "$TEST_PASS" -H ldaps://ldapserver:636 uid=cmsupport >/dev/null 2>&1; then
            log_info "✓ Bind authentication works with user credentials"
        else
            log_error "✗ Bind authentication failed"
            log_error "  Command attempted: ldapsearch -D uid=$TEST_USER,dc=cm,dc=cluster -w <password> -H ldaps://ldapserver:636 uid=cmsupport"
            VALIDATION_FAILED=1
        fi
        
        # Clean up test user
        log_info "Removing test user: $TEST_USER"
        if cmsh -c "user; remove $TEST_USER; commit" >/dev/null 2>&1; then
            log_info "✓ Test user removed successfully"
        else
            log_warn "⚠ Failed to remove test user - you may need to remove it manually"
            log_warn "  Run: cmsh -c 'user; remove $TEST_USER; commit'"
        fi
    else
        log_error "✗ Failed to create test user"
        VALIDATION_FAILED=1
    fi
    
    # ============================================================================
    # TEST 4: Verify slapd Configuration
    # ============================================================================
    echo ""
    log_info "Test 4: Verifying slapd configuration"
    echo ""
    
    slapd_conf="/cm/local/apps/openldap/etc/slapd.conf"
    
    if [[ -f "$slapd_conf" ]]; then
        if grep -q "^TLSVerifyClient try" "$slapd_conf"; then
            log_info "✓ TLSVerifyClient is set to 'try'"
        else
            log_error "✗ TLSVerifyClient is not set to 'try'"
            VALIDATION_FAILED=1
        fi
        
        if grep -q "^require authc" "$slapd_conf"; then
            log_info "✓ 'require authc' is present"
        else
            log_error "✗ 'require authc' is not present"
            VALIDATION_FAILED=1
        fi
        
        if systemctl is-active --quiet slapd 2>/dev/null; then
            log_info "✓ slapd service is running"
        else
            log_error "✗ slapd service is not running"
            VALIDATION_FAILED=1
        fi
    else
        log_error "✗ slapd.conf not found at $slapd_conf"
        VALIDATION_FAILED=1
    fi
    
    # ============================================================================
    # SUMMARY
    # ============================================================================
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                   Validation Summary${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ $VALIDATION_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ ALL VALIDATION TESTS PASSED${NC}"
        echo ""
        log_info "LDAP is configured correctly and working as expected:"
        log_info "  ✓ Certificate-based authentication (SASL EXTERNAL) works on all head nodes"
        log_info "  ✓ Bind credentials authentication works"
        log_info "  ✓ nslcd is configured with certificate auth (sasl_mech external) on all UP nodes"
        log_info "  ✓ User lookups work via nslcd/getent on all UP nodes"
        log_info "  ✓ slapd configuration is correct"
        echo ""
        exit 0
    else
        echo -e "${RED}✗ VALIDATION FAILED${NC}"
        echo ""
        log_error "One or more validation tests failed."
        log_error "Please review the errors above and check:"
        log_error "  1. Service logs: journalctl -u nslcd -u slapd"
        log_error "  2. Configuration files in /etc and software images"
        log_error "  3. Network connectivity between nodes"
        echo ""
        exit 1
    fi
fi

# ============================================================================
# WRITE MODE - Apply Configuration
# ============================================================================

if [[ "$MODE" == "write" ]]; then
    # Ensure the script is run as root
    if [[ $EUID -ne 0 ]]; then
       log_error "Write mode must be run as root."
       log_error "Please run: sudo $0 --write"
       exit 1
    fi
    
    log_info "Starting LDAP bind credentials configuration..."
    echo ""
    
    # ============================================================================
    # STEP 0: Validate SASL2 Support
    # ============================================================================
    log_info "Step 0: Validating SASL2 support..."
    
    SLAPD_PATH="/cm/local/apps/openldap/sbin/slapd"
    
    if [[ ! -f "$SLAPD_PATH" ]]; then
        log_error "slapd binary not found at $SLAPD_PATH"
        log_error "Cannot proceed without slapd"
        exit 1
    fi
    
    if ldd "$SLAPD_PATH" | grep -q "libsasl2"; then
        log_info "✓ SASL2 support detected in slapd"
    else
        log_error "═══════════════════════════════════════════════════════════"
        log_error "   SASL2 SUPPORT NOT FOUND - CANNOT PROCEED"
        log_error "═══════════════════════════════════════════════════════════"
        log_error ""
        log_error "The slapd binary does not have SASL2 support compiled in."
        log_error "Attempting to enable bind authentication will break your system."
        log_error ""
        log_error "To verify SASL2 support, run:"
        log_error "  ldd $SLAPD_PATH | grep sasl2"
        log_error ""
        log_error "Currently, SASL2 support is available on:"
        log_error "  - RedHat and derivative systems (CentOS, Rocky, RHEL, etc.)"
        log_error "  - Ubuntu-based systems may not have SASL2 support"
        log_error ""
        log_error "Please contact Bright Computing support for assistance."
        log_error "═══════════════════════════════════════════════════════════"
        exit 1
    fi
    
    echo ""
    
    # ============================================================================
    # STEP 1: Update OpenLDAP Client Configuration on Head Nodes
    # ============================================================================
    echo ""
    log_info "Step 1: Configuring OpenLDAP client (ldap.conf) on head nodes"
    head_nodes=$(discover_head_nodes)
    current_hostname=$(hostname -s)
    
    for node in $head_nodes; do
        log_info "Processing head node: $node"
        
        if [[ "$node" == "$current_hostname" ]]; then
            # Local head node
            if [[ -f "/etc/openldap/ldap.conf" ]]; then
                update_ldap_conf "/etc/openldap/ldap.conf"
            else
                log_warn "/etc/openldap/ldap.conf not found on local head node"
            fi
        else
            # Remote head node - update via SSH
            if ssh -n "$node" "test -f /etc/openldap/ldap.conf" 2>/dev/null; then
                if ssh -n "$node" "grep -q '^SASL_MECH external' /etc/openldap/ldap.conf" 2>/dev/null; then
                    log_info "SASL_MECH external already present in /etc/openldap/ldap.conf on $node"
                else
                    log_info "Adding 'SASL_MECH external' to /etc/openldap/ldap.conf on $node"
                    ssh -n "$node" "cp /etc/openldap/ldap.conf /etc/openldap/ldap.conf.backup.\$(date +%Y%m%d_%H%M%S) 2>/dev/null || true; printf '\n# Force external authentication by default (added by bcm_ldap_bind.sh)\nSASL_MECH external\n' >> /etc/openldap/ldap.conf" 2>/dev/null || log_warn "Failed to update /etc/openldap/ldap.conf on $node"
                fi
            else
                log_warn "/etc/openldap/ldap.conf not found on $node"
            fi
        fi
    done
    
    # ============================================================================
    # STEP 2: Update nslcd Configuration on Head Nodes
    # ============================================================================
    echo ""
    log_info "Step 2: Configuring nslcd.conf on head nodes"
    
    for node in $head_nodes; do
        log_info "Processing head node: $node"
        
        if [[ "$node" == "$current_hostname" ]]; then
            # Local head node
            if [[ -f "/etc/nslcd.conf" ]]; then
                update_nslcd_conf "/etc/nslcd.conf"
                
                if systemctl cat nslcd.service >/dev/null 2>&1; then
                    log_info "Restarting nslcd service on $node..."
                    if systemctl restart nslcd 2>/dev/null; then
                        log_info "✓ nslcd restarted on $node"
                    else
                        log_warn "Failed to restart nslcd service on $node"
                    fi
                else
                    log_warn "nslcd service not found on $node"
                fi
            else
                log_warn "nslcd.conf not found on local head node"
            fi
        else
            # Remote head node - update via SSH
            if ssh -n "$node" "test -f /etc/nslcd.conf" 2>/dev/null; then
                if ssh -n "$node" "grep -q '^sasl_mech external' /etc/nslcd.conf" 2>/dev/null; then
                    log_info "sasl_mech external already present in /etc/nslcd.conf on $node"
                else
                    log_info "Adding 'sasl_mech external' to /etc/nslcd.conf on $node"
                    ssh -n "$node" "cp /etc/nslcd.conf /etc/nslcd.conf.backup.\$(date +%Y%m%d_%H%M%S) 2>/dev/null || true; printf '\n# Use certificate as auth (added by bcm_ldap_bind.sh)\nsasl_mech external\n' >> /etc/nslcd.conf" 2>/dev/null || log_warn "Failed to update /etc/nslcd.conf on $node"
                fi
                
                if ssh -n "$node" "systemctl cat nslcd.service >/dev/null 2>&1"; then
                    log_info "Restarting nslcd service on $node..."
                    if ssh -n "$node" "systemctl restart nslcd" 2>/dev/null; then
                        log_info "✓ nslcd restarted on $node"
                    else
                        log_warn "Failed to restart nslcd on $node"
                    fi
                else
                    log_warn "nslcd service not found on $node"
                fi
            else
                log_warn "nslcd.conf not found on $node"
            fi
        fi
    done
    
    # ============================================================================
    # STEP 3: Update Software Images (OpenLDAP + nslcd)
    # ============================================================================
    echo ""
    log_info "Step 3: Configuring OpenLDAP and nslcd in software images"
    image_paths=$(get_software_image_paths)
    
    if [[ -n "$image_paths" ]]; then
        while IFS= read -r image_path; do
            if [[ -n "$image_path" ]]; then
                log_info "Processing software image: $image_path"
                
                image_ldap_conf="${image_path}/etc/openldap/ldap.conf"
                update_ldap_conf "$image_ldap_conf"
                
                image_nslcd_conf="${image_path}/etc/nslcd.conf"
                update_nslcd_conf "$image_nslcd_conf"
            fi
        done <<< "$image_paths"
    else
        log_warn "No software images to configure"
    fi
    
    # ============================================================================
    # STEP 4: Push Software Image Changes to Running Compute Nodes
    # ============================================================================
    echo ""
    log_info "Step 4: Pushing software image changes to running compute nodes"
    
    compute_nodes=$(cmsh -c "device list" | awk '$1 != "HeadNode" && NF >= 2 { print $2 }')
    
    if [[ -n "$compute_nodes" ]]; then
        node_count=$(echo "$compute_nodes" | wc -w)
        log_info "Found $node_count compute node(s)"
        
        up_nodes=$(cmsh -c "device status" | grep -E "\[\s*UP\s*\]" | awk '{print $1}' | grep -v "HeadNode")
        
        if [[ -n "$up_nodes" ]]; then
            up_count=$(echo "$up_nodes" | wc -w)
            log_info "Updating filesystem on $up_count running compute node(s) with imageupdate..."
            log_info "This may take several minutes..."
            
            cmsh -c "device; imageupdate -t physicalnode -s UP -w --wait" 2>&1 | while read -r line; do
                log_info "  $line"
            done || log_warn "imageupdate completed with warnings"
            
            log_info "Restarting nslcd service on compute nodes..."
            
            cmsh -c "device; foreach -t physicalnode -s UP * (pexec systemctl restart nslcd || true)" 2>&1 | while read -r line; do
                log_info "  $line"
            done || log_warn "nslcd restart completed with warnings"
            
            log_info "✓ Compute nodes updated successfully"
        else
            log_info "No compute nodes currently UP - skipping imageupdate"
            log_info "Changes will be applied when nodes are rebooted or powered on"
        fi
    else
        log_info "No compute nodes found - skipping imageupdate"
    fi
    
    # ============================================================================
    # STEP 5: Check for SSSD and Update Configuration if Present
    # ============================================================================
    echo ""
    log_info "Step 5: Checking for SSSD configuration"
    
    if systemctl cat sssd.service >/dev/null 2>&1; then
        if systemctl is-active --quiet sssd 2>/dev/null || systemctl is-enabled --quiet sssd 2>/dev/null; then
            sssd_conf="/etc/sssd/sssd.conf"
            
            if [[ -f "$sssd_conf" ]]; then
                log_info "SSSD detected, updating configuration..."
                
                cp "$sssd_conf" "${sssd_conf}.backup.$(date +%Y%m%d_%H%M%S)"
                
                if grep -q "ldap_uri" "$sssd_conf"; then
                    if grep -q "^[[:space:]]*ldap_sasl_mech[[:space:]]*=" "$sssd_conf"; then
                        log_info "ldap_sasl_mech already present in $sssd_conf"
                    else
                        log_info "Adding 'ldap_sasl_mech = EXTERNAL' to $sssd_conf"
                        sed -i '/ldap_uri[[:space:]]*=/a ldap_sasl_mech = EXTERNAL' "$sssd_conf"
                        
                        log_info "Restarting sssd service..."
                        systemctl restart sssd || log_warn "Failed to restart sssd service"
                    fi
                else
                    log_warn "ldap_uri not found in $sssd_conf; skipping SSSD SASL configuration"
                fi
            else
                log_warn "SSSD is installed but $sssd_conf not found"
            fi
        else
            log_info "SSSD service is not active or enabled, skipping SSSD configuration"
        fi
    else
        log_info "SSSD is not installed, skipping SSSD configuration"
    fi
    
    # ============================================================================
    # STEP 6: Update slapd Configuration for Bind Authentication on All Head Nodes
    # ============================================================================
    echo ""
    log_info "Step 6: Configuring slapd.conf for bind authentication on all head nodes"
    
    head_nodes=$(discover_head_nodes)
    current_hostname=$(hostname -s)
    slapd_conf="/cm/local/apps/openldap/etc/slapd.conf"
    
    for node in $head_nodes; do
        log_info "Processing head node: $node"
        
        if [[ "$node" == "$current_hostname" ]]; then
            # Local head node - update directly
            if [[ -f "$slapd_conf" ]]; then
                log_info "Found slapd.conf, updating configuration..."
                
                # Create backup only if one doesn't exist (preserve original state)
                if ! ls "${slapd_conf}.backup."* 1> /dev/null 2>&1; then
                    cp "$slapd_conf" "${slapd_conf}.backup.$(date +%Y%m%d_%H%M%S)"
                    log_info "  Created backup of original file"
                else
                    log_info "  Backup already exists, preserving original"
                fi
                
                if grep -q "^TLSVerifyClient" "$slapd_conf"; then
                    if grep -q "^TLSVerifyClient try" "$slapd_conf"; then
                        log_info "TLSVerifyClient already set to 'try'"
                    else
                        log_info "Updating TLSVerifyClient to 'try'"
                        sed -i 's/^TLSVerifyClient .*/TLSVerifyClient try/' "$slapd_conf"
                    fi
                else
                    log_info "Adding TLSVerifyClient try"
                    if grep -q "^TLSCertificateFile" "$slapd_conf"; then
                        sed -i '/^TLSCertificateFile/a TLSVerifyClient try' "$slapd_conf"
                    else
                        echo "TLSVerifyClient try" >> "$slapd_conf"
                    fi
                fi
                
                if grep -q "^require authc" "$slapd_conf"; then
                    log_info "require authc already present in slapd.conf"
                else
                    log_info "Adding 'require authc' to slapd.conf"
                    if grep -q "^access to" "$slapd_conf"; then
                        sed -i '0,/^access to/s/^access to/require authc\n\naccess to/' "$slapd_conf"
                    else
                        echo "" >> "$slapd_conf"
                        echo "# Require authentication" >> "$slapd_conf"
                        echo "require authc" >> "$slapd_conf"
                    fi
                fi
                
                if systemctl cat slapd.service >/dev/null 2>&1; then
                    log_info "Restarting slapd service on $node..."
                    systemctl restart slapd && log_info "✓ slapd restarted on $node" || log_warn "Failed to restart slapd on $node"
                else
                    log_warn "slapd service not found on $node"
                fi
            else
                log_warn "slapd.conf not found at $slapd_conf on $node"
            fi
        else
            # Remote head node - update via SSH
            if ssh -n "$node" "test -f $slapd_conf" 2>/dev/null; then
                log_info "Found slapd.conf on $node, updating configuration..."
                
                # Create backup only if one doesn't exist (preserve original state)
                if ! ssh -n "$node" "ls ${slapd_conf}.backup.* 1> /dev/null 2>&1" 2>/dev/null; then
                    ssh -n "$node" "cp $slapd_conf ${slapd_conf}.backup.\$(date +%Y%m%d_%H%M%S)" 2>/dev/null && log_info "  Created backup of original file on $node" || log_warn "Failed to create backup on $node"
                else
                    log_info "  Backup already exists on $node, preserving original"
                fi
                
                # Check and update TLSVerifyClient
                if ssh -n "$node" "grep -q '^TLSVerifyClient' $slapd_conf" 2>/dev/null; then
                    if ssh -n "$node" "grep -q '^TLSVerifyClient try' $slapd_conf" 2>/dev/null; then
                        log_info "TLSVerifyClient already set to 'try' on $node"
                    else
                        log_info "Updating TLSVerifyClient to 'try' on $node"
                        ssh -n "$node" "sed -i 's/^TLSVerifyClient .*/TLSVerifyClient try/' $slapd_conf" 2>/dev/null || log_warn "Failed to update TLSVerifyClient on $node"
                    fi
                else
                    log_info "Adding TLSVerifyClient try on $node"
                    if ssh -n "$node" "grep -q '^TLSCertificateFile' $slapd_conf" 2>/dev/null; then
                        ssh -n "$node" "sed -i '/^TLSCertificateFile/a TLSVerifyClient try' $slapd_conf" 2>/dev/null || log_warn "Failed to add TLSVerifyClient on $node"
                    else
                        ssh -n "$node" "echo 'TLSVerifyClient try' >> $slapd_conf" 2>/dev/null || log_warn "Failed to add TLSVerifyClient on $node"
                    fi
                fi
                
                # Check and update require authc
                if ssh -n "$node" "grep -q '^require authc' $slapd_conf" 2>/dev/null; then
                    log_info "require authc already present in slapd.conf on $node"
                else
                    log_info "Adding 'require authc' to slapd.conf on $node"
                    if ssh -n "$node" "grep -q '^access to' $slapd_conf" 2>/dev/null; then
                        ssh -n "$node" "sed -i '0,/^access to/s/^access to/require authc\n\naccess to/' $slapd_conf" 2>/dev/null || log_warn "Failed to add require authc on $node"
                    else
                        ssh -n "$node" "printf '\n# Require authentication\nrequire authc\n' >> $slapd_conf" 2>/dev/null || log_warn "Failed to add require authc on $node"
                    fi
                fi
                
                # Restart slapd on remote node
                if ssh -n "$node" "systemctl cat slapd.service >/dev/null 2>&1"; then
                    log_info "Restarting slapd service on $node..."
                    if ssh -n "$node" "systemctl restart slapd" 2>/dev/null; then
                        log_info "✓ slapd restarted on $node"
                    else
                        log_warn "Failed to restart slapd on $node"
                    fi
                else
                    log_warn "slapd service not found on $node"
                fi
            else
                log_warn "slapd.conf not found at $slapd_conf on $node"
            fi
        fi
        
        echo ""
    done
    
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    log_info "Configuration completed successfully!"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    log_info "Summary of changes:"
    log_info "  ✓ Validated SASL2 support in slapd"
    log_info "  ✓ Updated /etc/openldap/ldap.conf on head nodes"
    log_info "  ✓ Updated /etc/openldap/ldap.conf in software images"
    log_info "  ✓ Updated /etc/nslcd.conf on head nodes"
    log_info "  ✓ Updated /etc/nslcd.conf in software images"
    if [[ -n "$up_nodes" ]]; then
        log_info "  ✓ Pushed changes to running compute nodes (imageupdate)"
        log_info "  ✓ Restarted nslcd on compute nodes"
    else
        log_info "  ○ Compute node changes will apply on next boot"
    fi
    if systemctl cat sssd.service >/dev/null 2>&1; then
        log_info "  ✓ Updated SSSD configuration (if applicable)"
    fi
    log_info "  ✓ Updated slapd.conf for bind authentication on all head nodes (TLSVerifyClient=try, require authc)"
    log_info "  ✓ Restarted slapd service on all head nodes"
    echo ""
    log_info "Backup files have been created with timestamp suffixes:"
    log_info "  Find backups with: find /etc /cm -name '*.backup.*' -type f 2>/dev/null"
    echo ""
    log_info "Next steps:"
    log_info "  1. Verify services are running: systemctl status nslcd slapd"
    log_info "  2. Test LDAP authentication with your 3rd-party clients"
    log_info "  3. Monitor logs for any issues: journalctl -u nslcd -u slapd -f"
    if [[ -z "$up_nodes" ]] || [[ $(echo "$compute_nodes" | wc -w) -gt $(echo "$up_nodes" | wc -w) ]]; then
        echo ""
        log_info "Note: Some compute nodes were not running. They will get the"
        log_info "      updated configuration when they boot or are rebooted."
    fi
    echo ""
    
    exit 0
fi

# ============================================================================
# ROLLBACK MODE - Undo All Changes
# ============================================================================

if [[ "$MODE" == "rollback" ]]; then
    # Ensure the script is run as root
    if [[ $EUID -ne 0 ]]; then
       log_error "Rollback mode must be run as root."
       log_error "Please run: sudo $0 --rollback"
       exit 1
    fi
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          ROLLBACK MODE - Undoing Configuration Changes${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_warn "This will restore all configuration files from backups and remove"
    log_warn "changes made by the --write mode."
    echo ""
    
    # Ask for confirmation
    read -p "Are you sure you want to rollback all changes? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Rollback cancelled."
        exit 0
    fi
    
    log_info "Starting rollback process..."
    echo ""
    
    ROLLBACK_FAILED=0
    FILES_RESTORED=0
    
    # Function to restore a file from backup
    restore_from_backup() {
        local conf_file="$1"
        local actual_file="$conf_file"
        
        # If it's a symlink, resolve to the actual file
        if [[ -L "$conf_file" ]]; then
            # Check if this is within a software image path
            if [[ "$conf_file" =~ ^/cm/images/[^/]+ ]]; then
                # In an image: resolve symlink relative to image root
                local link_target=$(readlink "$conf_file")
                if [[ "$link_target" == /* ]]; then
                    # Absolute symlink: prepend image root
                    local image_root=$(echo "$conf_file" | sed 's|\(/cm/images/[^/]*\)/.*|\1|')
                    actual_file="${image_root}${link_target}"
                else
                    # Relative symlink: resolve relative to symlink's directory
                    actual_file="$(dirname "$conf_file")/$link_target"
                fi
                log_info "  $conf_file is a symlink, restoring actual file: $actual_file"
            else
                # Not in an image: use standard resolution
                actual_file=$(readlink -f "$conf_file")
                log_info "  $conf_file is a symlink, restoring actual file: $actual_file"
            fi
        fi
        
        if [[ ! -f "$actual_file" ]]; then
            log_warn "File not found: $actual_file - skipping"
            return 1
        fi
        
        # Find the backup file (should only be one - the original state)
        local backup_file=$(find "$(dirname "$actual_file")" -maxdepth 1 -name "$(basename "$actual_file").backup.*" -type f 2>/dev/null | head -n 1)
        
        if [[ -n "$backup_file" && -f "$backup_file" ]]; then
            log_info "Restoring $actual_file from backup: $backup_file"
            cp "$backup_file" "$actual_file" || {
                log_error "Failed to restore $actual_file"
                ROLLBACK_FAILED=1
                return 1
            }
            FILES_RESTORED=$((FILES_RESTORED + 1))
            return 0
        else
            log_warn "No backup found for $actual_file"
            return 1
        fi
    }
    
    # Function to remove lines added by the script
    remove_script_additions() {
        local conf_file="$1"
        local marker="$2"
        local actual_file="$conf_file"
        
        # If it's a symlink, resolve to the actual file
        if [[ -L "$conf_file" ]]; then
            # Check if this is within a software image path
            if [[ "$conf_file" =~ ^/cm/images/[^/]+ ]]; then
                # In an image: resolve symlink relative to image root
                local link_target=$(readlink "$conf_file")
                if [[ "$link_target" == /* ]]; then
                    # Absolute symlink: prepend image root
                    local image_root=$(echo "$conf_file" | sed 's|\(/cm/images/[^/]*\)/.*|\1|')
                    actual_file="${image_root}${link_target}"
                else
                    # Relative symlink: resolve relative to symlink's directory
                    actual_file="$(dirname "$conf_file")/$link_target"
                fi
                log_info "  $conf_file is a symlink, updating actual file: $actual_file"
            else
                # Not in an image: use standard resolution
                actual_file=$(readlink -f "$conf_file")
                log_info "  $conf_file is a symlink, updating actual file: $actual_file"
            fi
        fi
        
        if [[ ! -f "$actual_file" ]]; then
            return 0  # File doesn't exist, nothing to remove - not an error
        fi
        
        if grep -q "$marker" "$actual_file" 2>/dev/null; then
            log_info "Removing lines added by script from $actual_file"
            
            # Create a safety backup
            cp "$actual_file" "${actual_file}.pre-rollback.$(date +%Y%m%d_%H%M%S)"
            
            # Remove the comment line and the configuration line after it
            sed -i "/# Force external authentication by default (added by bcm_ldap_bind.sh)/,/^SASL_MECH external/d" "$actual_file" 2>/dev/null || true
            sed -i "/# Use certificate as auth (added by bcm_ldap_bind.sh)/,/^sasl_mech external/d" "$actual_file" 2>/dev/null || true
            sed -i "/ldap_sasl_mech = EXTERNAL/d" "$actual_file" 2>/dev/null || true
            sed -i "/# Require authentication/d" "$actual_file" 2>/dev/null || true
            sed -i "/^require authc$/d" "$actual_file" 2>/dev/null || true
            
            FILES_RESTORED=$((FILES_RESTORED + 1))
        fi
        
        return 0  # Always return success for rollback
    }
    
    # ============================================================================
    # STEP 1: Restore OpenLDAP client configuration on head nodes
    # ============================================================================
    echo ""
    log_info "Step 1: Restoring OpenLDAP client (ldap.conf) on head nodes"
    
    head_nodes=$(discover_head_nodes)
    current_hostname=$(hostname -s)
    
    for node in $head_nodes; do
        log_info "Processing head node: $node"
        
        if [[ "$node" == "$current_hostname" ]]; then
            # Local head node
            if [[ -f "/etc/openldap/ldap.conf" ]]; then
                if ! restore_from_backup "/etc/openldap/ldap.conf"; then
                    remove_script_additions "/etc/openldap/ldap.conf" "SASL_MECH external"
                fi
            fi
        else
            # Remote head node
            if ssh -n "$node" "test -f /etc/openldap/ldap.conf" 2>/dev/null; then
                log_info "Restoring ldap.conf on $node..."
                
                # Try to find and restore from backup on remote node (should only be one - original state)
                backup_file=$(ssh -n "$node" "find /etc/openldap -maxdepth 1 -name 'ldap.conf.backup.*' -type f 2>/dev/null | head -n 1" 2>/dev/null)
                
                if [[ -n "$backup_file" ]]; then
                    log_info "Restoring from backup: $backup_file"
                    ssh -n "$node" "cp '$backup_file' /etc/openldap/ldap.conf" 2>/dev/null && log_info "✓ Restored ldap.conf on $node" || log_warn "Failed to restore ldap.conf on $node"
                    FILES_RESTORED=$((FILES_RESTORED + 1))
                else
                    log_warn "No backup found on $node, attempting to remove script additions..."
                    ssh -n "$node" "sed -i '/# Force external authentication by default (added by bcm_ldap_bind.sh)/,/^SASL_MECH external/d' /etc/openldap/ldap.conf" 2>/dev/null && FILES_RESTORED=$((FILES_RESTORED + 1))
                fi
            fi
        fi
    done
    
    # ============================================================================
    # STEP 2: Restore nslcd configuration on head nodes
    # ============================================================================
    echo ""
    log_info "Step 2: Restoring nslcd.conf on head nodes"
    
    for node in $head_nodes; do
        log_info "Processing head node: $node"
        
        if [[ "$node" == "$current_hostname" ]]; then
            # Local head node
            if [[ -f "/etc/nslcd.conf" ]]; then
                if ! restore_from_backup "/etc/nslcd.conf"; then
                    remove_script_additions "/etc/nslcd.conf" "sasl_mech external"
                fi
                
                if systemctl cat nslcd.service >/dev/null 2>&1; then
                    log_info "Restarting nslcd service on $node..."
                    systemctl restart nslcd && log_info "✓ nslcd restarted on $node" || log_warn "Failed to restart nslcd service on $node"
                fi
            fi
        else
            # Remote head node
            if ssh -n "$node" "test -f /etc/nslcd.conf" 2>/dev/null; then
                log_info "Restoring nslcd.conf on $node..."
                
                # Try to find and restore from backup on remote node (should only be one - original state)
                backup_file=$(ssh -n "$node" "find /etc -maxdepth 1 -name 'nslcd.conf.backup.*' -type f 2>/dev/null | head -n 1" 2>/dev/null)
                
                if [[ -n "$backup_file" ]]; then
                    log_info "Restoring from backup: $backup_file"
                    ssh -n "$node" "cp '$backup_file' /etc/nslcd.conf" 2>/dev/null && log_info "✓ Restored nslcd.conf on $node" || log_warn "Failed to restore nslcd.conf on $node"
                    FILES_RESTORED=$((FILES_RESTORED + 1))
                else
                    log_warn "No backup found on $node, attempting to remove script additions..."
                    ssh -n "$node" "sed -i '/# Use certificate as auth (added by bcm_ldap_bind.sh)/,/^sasl_mech external/d' /etc/nslcd.conf" 2>/dev/null && FILES_RESTORED=$((FILES_RESTORED + 1))
                fi
                
                # Restart nslcd service on remote node
                if ssh -n "$node" "systemctl cat nslcd.service >/dev/null 2>&1" 2>/dev/null; then
                    log_info "Restarting nslcd service on $node..."
                    ssh -n "$node" "systemctl restart nslcd" 2>/dev/null && log_info "✓ nslcd restarted on $node" || log_warn "Failed to restart nslcd on $node"
                fi
            fi
        fi
    done
    
    # ============================================================================
    # STEP 3: Restore software images
    # ============================================================================
    echo ""
    log_info "Step 3: Restoring OpenLDAP and nslcd in software images"
    image_paths=$(get_software_image_paths)
    
    if [[ -n "$image_paths" ]]; then
        while IFS= read -r image_path; do
            if [[ -n "$image_path" ]]; then
                log_info "Processing software image: $image_path"
                
                image_ldap_conf="${image_path}/etc/openldap/ldap.conf"
                if ! restore_from_backup "$image_ldap_conf"; then
                    remove_script_additions "$image_ldap_conf" "SASL_MECH external"
                fi
                
                image_nslcd_conf="${image_path}/etc/nslcd.conf"
                if ! restore_from_backup "$image_nslcd_conf"; then
                    remove_script_additions "$image_nslcd_conf" "sasl_mech external"
                fi
            fi
        done <<< "$image_paths"
    fi
    
    # ============================================================================
    # STEP 4: Push changes to running compute nodes
    # ============================================================================
    echo ""
    log_info "Step 4: Pushing restored configuration to running compute nodes"
    
    compute_nodes=$(cmsh -c "device list" | awk '$1 != "HeadNode" && NF >= 2 { print $2 }')
    
    if [[ -n "$compute_nodes" ]]; then
        up_nodes=$(cmsh -c "device status" | grep -E "\[\s*UP\s*\]" | awk '{print $1}' | grep -v "HeadNode")
        
        if [[ -n "$up_nodes" ]]; then
            up_count=$(echo "$up_nodes" | wc -w)
            log_info "Updating filesystem on $up_count running compute node(s) with imageupdate..."
            log_info "This may take several minutes..."
            
            cmsh -c "device; imageupdate -t physicalnode -s UP -w --wait" 2>&1 | while read -r line; do
                log_info "  $line"
            done || log_warn "imageupdate completed with warnings"
            
            log_info "Restarting nslcd service on compute nodes..."
            
            cmsh -c "device; foreach -t physicalnode -s UP * (pexec systemctl restart nslcd || true)" 2>&1 | while read -r line; do
                log_info "  $line"
            done || log_warn "nslcd restart completed with warnings"
            
            log_info "✓ Compute nodes updated successfully"
        else
            log_info "No compute nodes currently UP - skipping imageupdate"
            log_info "Changes will be applied when nodes are rebooted or powered on"
        fi
    fi
    
    # ============================================================================
    # STEP 5: Restore SSSD configuration if present
    # ============================================================================
    echo ""
    log_info "Step 5: Restoring SSSD configuration"
    
    sssd_conf="/etc/sssd/sssd.conf"
    
    if systemctl cat sssd.service >/dev/null 2>&1; then
        if systemctl is-active --quiet sssd 2>/dev/null || systemctl is-enabled --quiet sssd 2>/dev/null; then
            if [[ -f "$sssd_conf" ]]; then
                log_info "SSSD detected, restoring configuration..."
                
                if ! restore_from_backup "$sssd_conf"; then
                    # Remove ldap_sasl_mech line if no backup exists
                    if grep -q "ldap_sasl_mech = EXTERNAL" "$sssd_conf"; then
                        log_info "Removing ldap_sasl_mech from $sssd_conf"
                        cp "$sssd_conf" "${sssd_conf}.pre-rollback.$(date +%Y%m%d_%H%M%S)"
                        sed -i '/^[[:space:]]*ldap_sasl_mech[[:space:]]*=[[:space:]]*EXTERNAL/d' "$sssd_conf"
                        FILES_RESTORED=$((FILES_RESTORED + 1))
                    fi
                fi
                
                log_info "Restarting sssd service..."
                systemctl restart sssd || log_warn "Failed to restart sssd service"
            fi
        fi
    fi
    
    # ============================================================================
    # STEP 6: Restore slapd configuration on all head nodes
    # ============================================================================
    echo ""
    log_info "Step 6: Restoring slapd.conf on all head nodes"
    
    head_nodes=$(discover_head_nodes)
    current_hostname=$(hostname -s)
    slapd_conf="/cm/local/apps/openldap/etc/slapd.conf"
    
    for node in $head_nodes; do
        log_info "Processing head node: $node"
        
        if [[ "$node" == "$current_hostname" ]]; then
            # Local head node - restore directly
            if [[ -f "$slapd_conf" ]]; then
                log_info "Restoring slapd.conf..."
                
                if ! restore_from_backup "$slapd_conf"; then
                    # If no backup, try to undo the changes manually
                    log_info "No backup found, attempting manual removal of changes..."
                    
                    if grep -q "^TLSVerifyClient try" "$slapd_conf" || grep -q "^require authc" "$slapd_conf"; then
                        cp "$slapd_conf" "${slapd_conf}.pre-rollback.$(date +%Y%m%d_%H%M%S)"
                        
                        # This is tricky - we don't know the original TLSVerifyClient value
                        # Best we can do is comment it out or remove it if we added it
                        log_warn "Cannot determine original TLSVerifyClient value on $node"
                        log_warn "You may need to manually verify slapd.conf settings on $node"
                        
                        # Remove require authc if present
                        sed -i '/^require authc$/d' "$slapd_conf" 2>/dev/null || true
                        sed -i '/# Require authentication/d' "$slapd_conf" 2>/dev/null || true
                        
                        FILES_RESTORED=$((FILES_RESTORED + 1))
                    fi
                fi
                
                if systemctl cat slapd.service >/dev/null 2>&1; then
                    log_info "Restarting slapd service on $node..."
                    systemctl restart slapd && log_info "✓ slapd restarted on $node" || log_warn "Failed to restart slapd on $node"
                fi
            fi
        else
            # Remote head node - restore via SSH
            if ssh -n "$node" "test -f $slapd_conf" 2>/dev/null; then
                log_info "Restoring slapd.conf on $node..."
                
                # Try to find and restore from backup on remote node (should only be one - original state)
                backup_file=$(ssh -n "$node" "find $(dirname "$slapd_conf") -maxdepth 1 -name '$(basename "$slapd_conf").backup.*' -type f 2>/dev/null | head -n 1" 2>/dev/null)
                
                if [[ -n "$backup_file" ]]; then
                    log_info "Restoring $slapd_conf from backup on $node: $backup_file"
                    ssh -n "$node" "cp '$backup_file' $slapd_conf" 2>/dev/null && FILES_RESTORED=$((FILES_RESTORED + 1)) || log_warn "Failed to restore from backup on $node"
                else
                    # No backup, try to undo changes manually
                    log_info "No backup found, attempting manual removal of changes on $node..."
                    
                    if ssh -n "$node" "grep -q '^TLSVerifyClient try' $slapd_conf || grep -q '^require authc' $slapd_conf" 2>/dev/null; then
                        ssh -n "$node" "cp $slapd_conf ${slapd_conf}.pre-rollback.\$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
                        
                        log_warn "Cannot determine original TLSVerifyClient value on $node"
                        log_warn "You may need to manually verify slapd.conf settings on $node"
                        
                        # Remove require authc if present
                        ssh -n "$node" "sed -i '/^require authc\$/d' $slapd_conf 2>/dev/null || true; sed -i '/# Require authentication/d' $slapd_conf 2>/dev/null || true" 2>/dev/null && FILES_RESTORED=$((FILES_RESTORED + 1))
                    fi
                fi
                
                if ssh -n "$node" "systemctl cat slapd.service >/dev/null 2>&1"; then
                    log_info "Restarting slapd service on $node..."
                    ssh -n "$node" "systemctl restart slapd" 2>/dev/null && log_info "✓ slapd restarted on $node" || log_warn "Failed to restart slapd on $node"
                fi
            fi
        fi
        
        echo ""
    done
    
    # ============================================================================
    # SUMMARY
    # ============================================================================
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                   Rollback Summary${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ $ROLLBACK_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ ROLLBACK COMPLETED SUCCESSFULLY${NC}"
        echo ""
        log_info "Summary:"
        log_info "  ✓ Restored $FILES_RESTORED configuration file(s)"
        log_info "  ✓ Restarted affected services (nslcd, sssd, slapd)"
        if [[ -n "$up_nodes" ]]; then
            log_info "  ✓ Pushed changes to running compute nodes"
        fi
        echo ""
        log_info "Backup files created during this rollback:"
        log_info "  Find them with: find /etc /cm -name '*.pre-rollback.*' -type f 2>/dev/null"
        echo ""
        log_info "Original backup files from --write mode are still available:"
        log_info "  Find them with: find /etc /cm -name '*.backup.*' -type f 2>/dev/null"
        echo ""
        log_info "Next steps:"
        log_info "  1. Verify services are running: systemctl status nslcd slapd"
        log_info "  2. Test LDAP authentication is working as expected"
        log_info "  3. Monitor logs for any issues: journalctl -u nslcd -u slapd -f"
        echo ""
    else
        echo -e "${RED}✗ ROLLBACK COMPLETED WITH WARNINGS${NC}"
        echo ""
        log_warn "Rollback completed but some issues were encountered."
        log_warn "Please review the messages above and verify your configuration."
        log_warn "You may need to manually check and fix some configuration files."
        echo ""
        exit 1
    fi
    
    exit 0
fi

# ============================================================================
# ROLLBACK-VALIDATE MODE - Verify System is in Original State
# ============================================================================

if [[ "$MODE" == "rollback-validate" ]]; then
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    ROLLBACK-VALIDATE MODE - Verifying Original State${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_info "Validating that system is in original state (before --write changes)..."
    echo ""
    
    VALIDATION_FAILED=0
    
    # Function to check if a file has script-added configurations
    check_file_not_modified() {
        local conf_file="$1"
        local marker="$2"
        local description="$3"
        local actual_file="$conf_file"
        
        # If it's a symlink, resolve to the actual file
        if [[ -L "$conf_file" ]]; then
            # Check if this is within a software image path
            if [[ "$conf_file" =~ ^/cm/images/[^/]+ ]]; then
                # In an image: resolve symlink relative to image root
                local link_target=$(readlink "$conf_file")
                if [[ "$link_target" == /* ]]; then
                    # Absolute symlink: prepend image root
                    local image_root=$(echo "$conf_file" | sed 's|\(/cm/images/[^/]*\)/.*|\1|')
                    actual_file="${image_root}${link_target}"
                else
                    # Relative symlink: resolve relative to symlink's directory
                    actual_file="$(dirname "$conf_file")/$link_target"
                fi
            else
                # Not in an image: use standard resolution
                actual_file=$(readlink -f "$conf_file")
            fi
        fi
        
        if [[ ! -f "$actual_file" ]]; then
            log_warn "File not found: $actual_file (skipping)"
            return 0
        fi
        
        if grep -q "$marker" "$actual_file" 2>/dev/null; then
            log_error "✗ $actual_file still has script-added configuration"
            log_error "  Found: $marker"
            VALIDATION_FAILED=1
            return 1
        else
            log_info "✓ $actual_file is in original state (no script modifications)"
            return 0
        fi
    }
    
    # ============================================================================
    # TEST 1: Verify Head Node Configuration Files
    # ============================================================================
    log_info "Test 1: Verifying head node configuration files on all head nodes"
    echo ""
    
    head_nodes=$(discover_head_nodes)
    current_hostname=$(hostname -s)
    
    for node in $head_nodes; do
        log_info "Checking head node: $node"
        
        if [[ "$node" == "$current_hostname" ]]; then
            # Local head node
            # Check /etc/openldap/ldap.conf
            if [[ -f "/etc/openldap/ldap.conf" ]]; then
                check_file_not_modified "/etc/openldap/ldap.conf" \
                    "# Force external authentication by default (added by bcm_ldap_bind.sh)" \
                    "OpenLDAP client config"
                
                # Also check for the actual configuration line
                if grep -q "^SASL_MECH external" "/etc/openldap/ldap.conf" 2>/dev/null; then
                    # Check if it has our comment above it
                    if grep -B1 "^SASL_MECH external" "/etc/openldap/ldap.conf" | grep -q "added by bcm_ldap_bind.sh"; then
                        log_error "✗ /etc/openldap/ldap.conf has script-added 'SASL_MECH external'"
                        VALIDATION_FAILED=1
                    else
                        log_info "✓ /etc/openldap/ldap.conf has 'SASL_MECH external' but not from script"
                    fi
                fi
            fi
            
            # Check /etc/nslcd.conf
            if [[ -f "/etc/nslcd.conf" ]]; then
                check_file_not_modified "/etc/nslcd.conf" \
                    "# Use certificate as auth (added by bcm_ldap_bind.sh)" \
                    "nslcd config"
                
                # Also check for the actual configuration line
                if grep -q "^sasl_mech external" "/etc/nslcd.conf" 2>/dev/null; then
                    # Check if it has our comment above it
                    if grep -B1 "^sasl_mech external" "/etc/nslcd.conf" | grep -q "added by bcm_ldap_bind.sh"; then
                        log_error "✗ /etc/nslcd.conf has script-added 'sasl_mech external'"
                        VALIDATION_FAILED=1
                    else
                        log_info "✓ /etc/nslcd.conf has 'sasl_mech external' but not from script"
                    fi
                fi
            fi
        else
            # Remote head node - check via SSH
            if ssh -n "$node" "test -f /etc/openldap/ldap.conf" 2>/dev/null; then
                if ssh -n "$node" "grep -q '# Force external authentication by default (added by bcm_ldap_bind.sh)' /etc/openldap/ldap.conf" 2>/dev/null; then
                    log_error "✗ /etc/openldap/ldap.conf on $node has script-added configuration"
                    VALIDATION_FAILED=1
                else
                    log_info "✓ /etc/openldap/ldap.conf on $node is in original state"
                fi
            fi
            
            if ssh -n "$node" "test -f /etc/nslcd.conf" 2>/dev/null; then
                if ssh -n "$node" "grep -q '# Use certificate as auth (added by bcm_ldap_bind.sh)' /etc/nslcd.conf" 2>/dev/null; then
                    log_error "✗ /etc/nslcd.conf on $node has script-added configuration"
                    VALIDATION_FAILED=1
                else
                    log_info "✓ /etc/nslcd.conf on $node is in original state"
                fi
            fi
        fi
        echo ""
    done
    
    # Check /etc/sssd/sssd.conf if SSSD is present
    if systemctl cat sssd.service >/dev/null 2>&1; then
        if [[ -f "/etc/sssd/sssd.conf" ]]; then
            if grep -q "^[[:space:]]*ldap_sasl_mech[[:space:]]*=[[:space:]]*EXTERNAL" "/etc/sssd/sssd.conf" 2>/dev/null; then
                log_error "✗ /etc/sssd/sssd.conf has 'ldap_sasl_mech = EXTERNAL'"
                log_error "  This was likely added by the script"
                VALIDATION_FAILED=1
            else
                log_info "✓ /etc/sssd/sssd.conf is in original state"
            fi
        fi
    fi
    
    # ============================================================================
    # TEST 2: Verify Software Image Configuration Files
    # ============================================================================
    echo ""
    log_info "Test 2: Verifying software image configuration files"
    echo ""
    
    image_paths=$(get_software_image_paths)
    
    if [[ -n "$image_paths" ]]; then
        while IFS= read -r image_path; do
            if [[ -n "$image_path" ]]; then
                log_info "Checking software image: $image_path"
                
                # Check ldap.conf in image
                image_ldap_conf="${image_path}/etc/openldap/ldap.conf"
                if [[ -f "$image_ldap_conf" ]]; then
                    if grep -q "# Force external authentication by default (added by bcm_ldap_bind.sh)" "$image_ldap_conf" 2>/dev/null; then
                        log_error "  ✗ ldap.conf has script-added configuration"
                        VALIDATION_FAILED=1
                    else
                        log_info "  ✓ ldap.conf is in original state"
                    fi
                fi
                
                # Check nslcd.conf in image
                image_nslcd_conf="${image_path}/etc/nslcd.conf"
                if [[ -f "$image_nslcd_conf" ]]; then
                    if grep -q "# Use certificate as auth (added by bcm_ldap_bind.sh)" "$image_nslcd_conf" 2>/dev/null; then
                        log_error "  ✗ nslcd.conf has script-added configuration"
                        VALIDATION_FAILED=1
                    else
                        log_info "  ✓ nslcd.conf is in original state"
                    fi
                fi
            fi
        done <<< "$image_paths"
    else
        log_info "No software images found"
    fi
    
    # ============================================================================
    # TEST 3: Verify Compute Node Configuration (if UP)
    # ============================================================================
    echo ""
    log_info "Test 3: Verifying compute node configuration files"
    echo ""
    
    compute_nodes=$(cmsh -c "device list" | awk '$1 != "HeadNode" && NF >= 2 { print $2 }')
    
    if [[ -n "$compute_nodes" ]]; then
        up_nodes=$(cmsh -c "device status" | grep -E "\[\s*UP\s*\]" | awk '{print $1}' | grep -v "HeadNode")
        
        if [[ -n "$up_nodes" ]]; then
            while IFS= read -r node; do
                if [[ -n "$node" ]]; then
                    log_info "Testing node: $node"
                    
                    # Check nslcd.conf on compute node
                    if ssh -n "$node" "test -f /etc/nslcd.conf" 2>/dev/null; then
                        if ssh -n "$node" "grep -q '# Use certificate as auth (added by bcm_ldap_bind.sh)' /etc/nslcd.conf 2>/dev/null"; then
                            log_error "  ✗ nslcd.conf has script-added configuration"
                            VALIDATION_FAILED=1
                        else
                            log_info "  ✓ nslcd.conf is in original state"
                        fi
                    fi
                    
                    # Check ldap.conf on compute node
                    if ssh -n "$node" "test -f /etc/openldap/ldap.conf" 2>/dev/null; then
                        if ssh -n "$node" "grep -q '# Force external authentication by default (added by bcm_ldap_bind.sh)' /etc/openldap/ldap.conf 2>/dev/null"; then
                            log_error "  ✗ ldap.conf has script-added configuration"
                            VALIDATION_FAILED=1
                        else
                            log_info "  ✓ ldap.conf is in original state"
                        fi
                    fi
                fi
            done <<< "$up_nodes"
        else
            log_warn "No compute nodes are currently UP - skipping node checks"
        fi
    else
        log_info "No compute nodes found in cluster"
    fi
    
    # ============================================================================
    # TEST 4: Verify slapd.conf Configuration on all head nodes
    # ============================================================================
    echo ""
    log_info "Test 4: Verifying slapd.conf configuration on all head nodes"
    echo ""
    
    slapd_conf="/cm/local/apps/openldap/etc/slapd.conf"
    
    for node in $head_nodes; do
        log_info "Checking slapd.conf on head node: $node"
        
        if [[ "$node" == "$current_hostname" ]]; then
            # Local head node
            if [[ -f "$slapd_conf" ]]; then
                # Check for 'require authc' with our comment
                if grep -q "^require authc" "$slapd_conf" 2>/dev/null; then
                    # Check if it has our comment above it
                    if grep -B1 "^require authc" "$slapd_conf" | grep -q "# Require authentication"; then
                        log_error "✗ slapd.conf has script-added 'require authc'"
                        VALIDATION_FAILED=1
                    else
                        log_info "✓ slapd.conf has 'require authc' but not from script"
                    fi
                else
                    log_info "✓ slapd.conf does not have 'require authc'"
                fi
                
                # For TLSVerifyClient, we can't easily tell if we modified it
                # Just report its current value
                if grep -q "^TLSVerifyClient" "$slapd_conf" 2>/dev/null; then
                    current_value=$(grep "^TLSVerifyClient" "$slapd_conf" | awk '{print $2}')
                    if [[ "$current_value" == "try" ]]; then
                        log_warn "⚠ slapd.conf has 'TLSVerifyClient try' (may be from script)"
                        log_warn "  Cannot definitively determine if this was the original value"
                    else
                        log_info "✓ slapd.conf has TLSVerifyClient = $current_value (not 'try')"
                    fi
                else
                    log_info "✓ slapd.conf does not have TLSVerifyClient directive"
                fi
            else
                log_warn "slapd.conf not found at $slapd_conf"
            fi
        else
            # Remote head node - check via SSH
            if ssh -n "$node" "test -f $slapd_conf" 2>/dev/null; then
                # Check for 'require authc' with our comment
                if ssh -n "$node" "grep -q '^require authc' $slapd_conf" 2>/dev/null; then
                    # Check if it has our comment above it
                    if ssh -n "$node" "grep -B1 '^require authc' $slapd_conf | grep -q '# Require authentication'" 2>/dev/null; then
                        log_error "✗ slapd.conf on $node has script-added 'require authc'"
                        VALIDATION_FAILED=1
                    else
                        log_info "✓ slapd.conf on $node has 'require authc' but not from script"
                    fi
                else
                    log_info "✓ slapd.conf on $node does not have 'require authc'"
                fi
                
                # Check TLSVerifyClient
                if ssh -n "$node" "grep -q '^TLSVerifyClient' $slapd_conf" 2>/dev/null; then
                    current_value=$(ssh -n "$node" "grep '^TLSVerifyClient' $slapd_conf | awk '{print \$2}'" 2>/dev/null)
                    if [[ "$current_value" == "try" ]]; then
                        log_warn "⚠ slapd.conf on $node has 'TLSVerifyClient try' (may be from script)"
                        log_warn "  Cannot definitively determine if this was the original value"
                    else
                        log_info "✓ slapd.conf on $node has TLSVerifyClient = $current_value (not 'try')"
                    fi
                else
                    log_info "✓ slapd.conf on $node does not have TLSVerifyClient directive"
                fi
            else
                log_warn "slapd.conf not found on $node"
            fi
        fi
        echo ""
    done
    
    # ============================================================================
    # TEST 5: Check for Backup Files
    # ============================================================================
    echo ""
    log_info "Test 5: Checking for backup files"
    echo ""
    
    backup_files=$(find /etc /cm -name '*.backup.*' -type f 2>/dev/null | head -n 10)
    
    if [[ -n "$backup_files" ]]; then
        backup_count=$(find /etc /cm -name '*.backup.*' -type f 2>/dev/null | wc -l)
        log_info "Found $backup_count backup file(s) from --write mode:"
        echo "$backup_files" | while read -r backup; do
            log_info "  - $backup"
        done
        log_info "Note: Backup files are intentionally preserved after --rollback for safety"
        log_info "      You can manually delete them once you're satisfied with the rollback"
    else
        log_info "✓ No backup files found (--write was never run, or backups were manually cleaned up)"
    fi
    
    # ============================================================================
    # SUMMARY
    # ============================================================================
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}              Rollback-Validation Summary${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ $VALIDATION_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ SYSTEM IS IN ORIGINAL STATE${NC}"
        echo ""
        log_info "All validation checks passed:"
        log_info "  ✓ Configuration files do not have script-added modifications"
        log_info "  ✓ Software images are in original state"
        log_info "  ✓ Compute nodes (if checked) are in original state"
        log_info "  ✓ slapd.conf appears to be in original state"
        echo ""
        log_info "This indicates either:"
        log_info "  1. The --write mode was never run, OR"
        log_info "  2. The --rollback mode was successfully executed"
        echo ""
        exit 0
    else
        echo -e "${RED}✗ SYSTEM IS NOT IN ORIGINAL STATE${NC}"
        echo ""
        log_error "System has modifications from --write mode:"
        log_error "  • Configuration files still have script-added settings"
        log_error "  • The system has NOT been successfully rolled back"
        echo ""
        log_info "To restore the original state, run:"
        log_info "  ${GREEN}sudo $0 --rollback${NC}"
        echo ""
        exit 1
    fi
fi

# Should never reach here
log_error "Unknown mode: $MODE"
exit 1

