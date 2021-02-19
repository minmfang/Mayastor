#!/usr/bin/env bash

# Ensure the CI registry has the required images.
# The first parameter is the registry, the second is the tag.
# If any of the images are absent, the script pulls each
# from dockerhub and pushes it to the CI registry.

set -euo pipefail

function synchImage {
  registry=$1
  image_name=$2
  tag=$3

  dockerhub_image="mayadata/${image_name}:${tag}"
  ci_image=${registry}/${dockerhub_image}

  #check if image is in registry
  listing=$(curl --silent -f -lSL ${registry}/v2/mayadata/${image_name}/tags/list)
  found=$(echo ${listing} | grep ${tag} || true)

  if [ -z "${found}" ]; then # not in CI registry
    docker image pull --quiet ${dockerhub_image}
    docker tag ${dockerhub_image} ${ci_image}
    docker push ${ci_image}
  else
    echo image ${dockerhub_image} already in registry ${registry}
  fi
}

if [ $# -ne 2 ]; then
    echo "usage $(basename $0) <registry> <tag>"
    exit 1
fi

synchImage $1 moac $2
synchImage $1 mayastor $2
synchImage $1 mayastor-csi $2

