# Copyright 2020 Hewlett Packard Enterprise Development LP
#
# This spec file generate an RPM that installs a collection of CSM scripts
# into a directory on the filesystem
#

%define install_dir /opt/cray/csm

Requires: bash
Requires: craycli-wrapper
Requires: jq

BuildArch: noarch

Name: hpe-csm-scripts
License: HPE Proprietary
Summary: Installs several scripts that are useful for various purposes such as troubleshooting
Version: %(cat .version)
Release: %(echo ${BUILD_METADATA})
Source: %{name}-%{version}.tar.bz2
Vendor: Hewlett Packard Enterprise Development LP

%description
Installs several scripts that are useful for various purposes such as troubleshooting.

%prep
%setup -q

%build

%install
install -m 755 -d %{buildroot}%{install_dir}/
cp -r scripts %{buildroot}%{install_dir}/

%clean

%files
%license LICENSE
%{install_dir}/scripts/

%changelog
