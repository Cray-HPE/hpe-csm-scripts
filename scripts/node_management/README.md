# Node Management Scripts

Place scripts for working with node configurations / customizations here.

The current scripts are:

- make_node_groups: create HSM node groups based on NCN functional categories:
  - master: a group of nodes designated as Kubernetes Master nodes
  - worker: a group of nodes designated as Kubernetes Worker nodes
  - storage: a group of nodes designated as Storage nodes
  - uai: a sub-group of Kubernetes Worker nodes allowed to run UAIs
