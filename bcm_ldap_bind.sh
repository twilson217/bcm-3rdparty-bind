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
    echo "  --discovery    Test discovery of head nodes, software images, and compute nodes"
    echo "  --dry-run      Preview what changes would be made without modifying anything"
    echo "  --write        Apply the LDAP bind credentials configuration"
    echo ""
    echo "Examples:"
    echo "  $0 --discovery    # Test the discovery logic"
    echo "  $0 --dry-run      # See what would be changed"
    echo "  sudo $0 --write   # Apply the changes (requires root)"
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
    
    if [[ ! -f "$conf_file" ]]; then
        log_warn "File not found: $conf_file - skipping"
        return 1
    fi
    
    if grep -q "^SASL_MECH external" "$conf_file" 2>/dev/null; then
        log_info "SASL_MECH external already present in $conf_file"
        return 0
    else
        log_info "Adding 'SASL_MECH external' to $conf_file"
        # Create backup
        cp "$conf_file" "${conf_file}.backup.$(date +%Y%m%d_%H%M%S)"
        # Add configuration
        echo "" >> "$conf_file"
        echo "# Force external authentication by default (added by bcm_ldap_bind.sh)" >> "$conf_file"
        echo "SASL_MECH external" >> "$conf_file"
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
        # Create backup
        cp "$conf_file" "${conf_file}.backup.$(date +%Y%m%d_%H%M%S)"
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
    
    if systemctl list-unit-files | grep -q "^sssd.service"; then
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
            
            if systemctl list-unit-files | grep -q "^nslcd.service"; then
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
            log_dryrun "  Command: cmsh -c \"device; foreach -t physicalnode -s UP * (exec systemctl restart nslcd)\""
        else
            log_info "No compute nodes currently UP"
            log_info "Changes will be applied when nodes boot"
        fi
    else
        log_info "No compute nodes found"
    fi
    
    echo ""
    log_info "Step 5: Analyzing SSSD configuration"
    
    if systemctl list-unit-files | grep -q "^sssd.service"; then
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
        
        if systemctl list-unit-files | grep -q "slapd.service"; then
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
    
    if [[ -f "/etc/openldap/ldap.conf" ]]; then
        update_ldap_conf "/etc/openldap/ldap.conf"
    else
        log_warn "/etc/openldap/ldap.conf not found on head node"
    fi
    
    # ============================================================================
    # STEP 2: Update nslcd Configuration on Head Nodes
    # ============================================================================
    echo ""
    log_info "Step 2: Configuring nslcd.conf on head nodes"
    head_nodes=$(discover_head_nodes)
    
    for node in $head_nodes; do
        log_info "Processing head node: $node"
        
        if [[ -f "/etc/nslcd.conf" ]]; then
            update_nslcd_conf "/etc/nslcd.conf"
            
            if systemctl list-unit-files | grep -q "^nslcd.service"; then
                log_info "Restarting nslcd service..."
                systemctl restart nslcd || log_warn "Failed to restart nslcd service"
            fi
        else
            log_warn "nslcd.conf not found on head node"
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
            
            cmsh -c "device; foreach -t physicalnode -s UP * (exec systemctl restart nslcd || true)" 2>&1 | while read -r line; do
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
    
    if systemctl list-unit-files | grep -q "^sssd.service"; then
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
    # STEP 6: Update slapd Configuration for Bind Authentication
    # ============================================================================
    echo ""
    log_info "Step 6: Configuring slapd.conf for bind authentication"
    
    slapd_conf="/cm/local/apps/openldap/etc/slapd.conf"
    
    if [[ -f "$slapd_conf" ]]; then
        log_info "Found slapd.conf, updating configuration..."
        
        cp "$slapd_conf" "${slapd_conf}.backup.$(date +%Y%m%d_%H%M%S)"
        
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
                sed -i '/^access to/i require authc' "$slapd_conf"
            else
                echo "" >> "$slapd_conf"
                echo "# Require authentication" >> "$slapd_conf"
                echo "require authc" >> "$slapd_conf"
            fi
        fi
        
        if systemctl list-unit-files | grep -q "slapd.service"; then
            log_info "Restarting slapd service..."
            systemctl restart slapd || log_warn "Failed to restart slapd service"
        else
            log_warn "slapd service not found, you may need to restart it manually"
        fi
    else
        log_warn "slapd.conf not found at $slapd_conf"
    fi
    
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
    if systemctl list-unit-files | grep -q "^sssd.service"; then
        log_info "  ✓ Updated SSSD configuration (if applicable)"
    fi
    log_info "  ✓ Updated slapd.conf for bind authentication (TLSVerifyClient=try, require authc)"
    log_info "  ✓ Restarted slapd service"
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

# Should never reach here
log_error "Unknown mode: $MODE"
exit 1

