# BCM LDAP Bind Credentials Configuration

Automated configuration script for enabling 3rd-party LDAP clients with bind credentials in NVIDIA Bright Cluster Manager (BCM) environments.

Based on: [Bright Computing KB Article](https://kb.brightcomputing.com/knowledge-base/3rd-party-ldap-client-with-bind-credentials/)

## Quick Start

```bash
# Test discovery
./bcm_ldap_bind.sh --discovery

# Preview changes
./bcm_ldap_bind.sh --dry-run

# Apply configuration (requires root)
sudo ./bcm_ldap_bind.sh --write

# Validate LDAP is working (requires root)
sudo ./bcm_ldap_bind.sh --validate
```

## Prerequisites

- Root access to a BCM head node
- **SASL2 support in slapd** (script validates and aborts if missing)
  - Available on RedHat-based systems (CentOS, Rocky, RHEL, AlmaLinux, etc.)
  - May not be available on Ubuntu-based BCM systems
  - Verify: `ldd /cm/local/apps/openldap/sbin/slapd | grep sasl2`
- BCM command-line tools (`cmsh`)

## What It Does

The script automates the complete configuration process:

1. **Validates SASL2 Support** - Aborts if not present to prevent system breakage
2. **Updates OpenLDAP Configuration** - Adds `SASL_MECH external` to ldap.conf
3. **Updates nslcd Configuration** - Adds `sasl_mech external` to nslcd.conf
4. **Updates Software Images** - Modifies both ldap.conf and nslcd.conf in all images
5. **Updates Running Compute Nodes** - Pushes changes via `imageupdate -w` and restarts nslcd
6. **Updates SSSD** (optional) - Configures if installed
7. **Updates slapd** - Changes TLSVerifyClient to 'try' and adds 'require authc'

## Usage

### Discovery Mode

Test the discovery logic without making changes:

```bash
./bcm_ldap_bind.sh --discovery
```

Shows:
- Head nodes discovered
- Software images and paths
- Compute nodes and their status
- File existence checks

### Dry-Run Mode

Preview what would be changed:

```bash
./bcm_ldap_bind.sh --dry-run
```

Shows:
- SASL2 validation status
- Files that would be modified
- Configuration changes to be made
- Services that would be restarted

### Write Mode

Apply the configuration (requires root):

```bash
sudo ./bcm_ldap_bind.sh --write
```

The script will:
- Create timestamped backups of all modified files
- Update all configuration files
- Push changes to running compute nodes
- Restart affected services
- Provide a summary of all changes

### Validate Mode

Validate that LDAP and bind authentication are working correctly:

```bash
sudo ./bcm_ldap_bind.sh --validate
```

This performs comprehensive tests:
- **Test 1:** Validates LDAP on head node (nslcd service, user lookup, certificate auth)
- **Test 2:** Validates LDAP on all UP compute nodes (nslcd service, user lookup)
- **Test 3:** Creates a temporary test user and validates bind credentials authentication
- **Test 4:** Verifies slapd configuration (TLSVerifyClient, require authc, service status)

The test user is automatically cleaned up after validation.

### Help

```bash
./bcm_ldap_bind.sh --help
```

## Files Modified

### Head Nodes
- `/etc/openldap/ldap.conf`
- `/etc/nslcd.conf`
- `/etc/sssd/sssd.conf` (if SSSD installed)
- `/cm/local/apps/openldap/etc/slapd.conf`

### Software Images
- `<image_path>/etc/openldap/ldap.conf`
- `<image_path>/etc/nslcd.conf`

### Compute Nodes
- Changes pushed via `imageupdate -w`
- nslcd service restarted automatically

## Verification

After running the script:

```bash
# Check services
systemctl status nslcd slapd

# Verify configuration
grep "SASL_MECH external" /etc/openldap/ldap.conf
grep "sasl_mech external" /etc/nslcd.conf
grep "TLSVerifyClient try" /cm/local/apps/openldap/etc/slapd.conf
grep "require authc" /cm/local/apps/openldap/etc/slapd.conf

# Test LDAP authentication
# (with your 3rd-party LDAP client)
```

## Rollback

The script creates timestamped backups of all modified files:

```bash
# Find backups
find /etc /cm -name '*.backup.*' -type f 2>/dev/null

# Restore a file
cp /etc/nslcd.conf.backup.20231103_143025 /etc/nslcd.conf
systemctl restart nslcd
```

## Troubleshooting

### SASL2 Not Found

If the script aborts due to missing SASL2 support:
- Contact Bright Computing support
- SASL2 may not be available on Ubuntu-based BCM systems
- Do not proceed without SASL2 support

### Discovery Fails

If head nodes or images aren't discovered:

```bash
# Check cmsh commands manually
cmsh -c "device list"
cmsh -c "softwareimage;list"
```

### Service Restart Fails

Check logs:

```bash
journalctl -u nslcd -n 50
journalctl -u slapd -n 50
```

### Compute Nodes Not Updated

The script only updates nodes with status=UP. For offline nodes:

```bash
# Check node status
cmsh -c "device status"

# Reboot offline nodes to apply changes
cmsh -c "device power on -n node002"
```

## Technical Details

### Discovery Method

- **Head Nodes:** `cmsh -c "device list"` filtered by Type=HeadNode
- **Software Images:** `cmsh -c "softwareimage;list"` extracting paths
- **Compute Nodes:** Device list filtered for non-HeadNode types

### Compute Node Updates

Running nodes are updated automatically:

```bash
# Push filesystem changes
cmsh -c "device; imageupdate -t physicalnode -s UP -w --wait"

# Restart service
cmsh -c "device; foreach -t physicalnode -s UP * (exec systemctl restart nslcd)"
```

### Safety Features

- SASL2 pre-flight validation
- Timestamped backups before all modifications
- Idempotent operations (safe to run multiple times)
- Status checks before node updates
- Service existence checks before restarts

## Environment

Tested on:
- Ubuntu 24.04 LTS
- BCM with head node + compute node architecture
- Software images in default and custom locations

## References

- [Bright Computing KB: 3rd-party LDAP client with bind credentials](https://kb.brightcomputing.com/knowledge-base/3rd-party-ldap-client-with-bind-credentials/)
- [BCM Documentation](https://kb.brightcomputing.com/)

## Support

For issues:
1. Run `./bcm_ldap_bind.sh --discovery` to validate environment
2. Run `./bcm_ldap_bind.sh --dry-run` to preview changes
3. Check service logs: `journalctl -u nslcd -u slapd`
4. Review [KB article](https://kb.brightcomputing.com/knowledge-base/3rd-party-ldap-client-with-bind-credentials/) for manual steps
5. Contact Bright Computing support for SASL2 issues

---

**Version:** 3.0  
**Last Updated:** November 3, 2025
