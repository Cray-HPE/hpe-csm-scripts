# Copyright 2020 Hewlett Packard Enterprise Development LP
#
# This spec file generate an RPM that installs a collection of CSM scripts
# into a directory on the filesystem
#

%define install_dir /opt/cray/csm

Requires: bash
Requires: jq

Name: hpe-csm-scripts
BuildArch: noarch
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}
License: HPE Proprietary
Summary: Installs helper scripts for trouble-shooting or triage.
Version: %(cat .version)
Release: %(echo ${BUILD_METADATA})
Source: %{name}-%{version}.tar.bz2
Vendor: Hewlett Packard Enterprise Development LP

%description

%prep

%setup -q

%build

%install
install -m 0755 -d %{buildroot}%{install_dir}/
cp -r scripts %{buildroot}%{install_dir}/

%clean

%files
%license LICENSE
%{install_dir}/scripts/

%changelog
