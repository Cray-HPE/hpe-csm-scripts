// Copyright 2020 Hewlett Packard Enterprise Development LP

@Library("dst-shared") _

rpmBuild(
    specfile: "hpe-csm-scripts.spec",
    fanout_params: ["sle15sp2"],
    channel: "casm-cloud-alerts",
    product: "csm",
    target_node: "ncn",
    slack_notify : ['', 'SUCCESS', 'FAILURE', 'FIXED']
)