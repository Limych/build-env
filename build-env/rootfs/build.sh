#!/usr/bin/env bash
# ==============================================================================
#
# Community Hass.io Add-ons: Build Environment
#
# Script for building our cross platform Hass.io Docker images.
#
# ==============================================================================
set -o errexit  # Exit script when a command exits with non-zero status
set -o errtrace # Exit on error inside any functions or sub-shells
set -o nounset  # Exit script on use of an undefined variable
set -o pipefail # Return exit status of the last command in the pipe that failed

# ==============================================================================
# GLOBALS
# ==============================================================================
readonly EX_OK=0                # Successful termination
readonly EX_UNKNOWN=1           # Unknown error occured
readonly EX_CROSS=3             # Failed enabling cross compile features
readonly EX_DOCKER_BUILD=4      # Docker build failed
readonly EX_DOCKER_DIE=5        # Took to long for container to die
readonly EX_DOCKER_PUSH=6       # Failed pushing Docker image
readonly EX_DOCKER_TAG=7        # Failed setting Docker tag
readonly EX_DOCKER_TIMEOUT=8    # Timout starting docker
readonly EX_DOCKERFILE=9        # Dockerfile is missing?
readonly EX_GIT_CLONE=10        # Failed cloning Git repository
readonly EX_INVALID_TYPE=11     # Invalid build type
readonly EX_MULTISTAGE=12       # Dockerfile contains multiple stages
readonly EX_NO_ARCHS=13         # No architectures to build
readonly EX_NO_FROM=14          # Missing image to build from
readonly EX_NO_IMAGE_NAME=15    # Missing name of image to build
readonly EX_NOT_EMPTY=16        # Workdirectory is not empty
readonly EX_NOT_GIT=17          # This is not a Git repository
readonly EX_PRIVILEGES=18       # Missing extended privileges
readonly EX_SUPPORTED=19        # Requested build architecture is not supported
readonly EX_VERSION=20          # Version not found and specified

# Constants
readonly DOCKER_PIDFILE='/var/run/docker.pid' # Docker daemon PID file
readonly DOCKER_TIMEOUT=20  # Wait 20 seconds for docker to start/exit

# Global variables
declare -a BUILD_ARCHS
declare -A BUILD_ARCHS_FROM
declare -A BUILD_ARGS
declare -a EXISTING_LABELS
declare -a SUPPORTED_ARCHS
declare -i DOCKER_PID
declare BUILD_ALL=false
declare BUILD_BRANCH
declare BUILD_IMAGE
declare BUILD_PARALLEL
declare BUILD_REF
declare BUILD_REPOSITORY
declare BUILD_TARGET
declare BUILD_TYPE
declare BUILD_VERSION
declare DOCKER_CACHE
declare DOCKER_PUSH
declare DOCKER_SQUASH
declare DOCKER_TAG_LATEST
declare DOCKER_TAG_TEST
declare DOCKERFILE
declare TRAPPED

# Defaults values
BUILD_ARCHS=()
BUILD_BRANCH='master'
BUILD_PARALLEL=true
BUILD_TARGET=$(pwd)
DOCKER_CACHE=true
DOCKER_PID=9999999999
DOCKER_PUSH=false
DOCKER_SQUASH=true
DOCKER_TAG_LATEST=false
DOCKER_TAG_TEST=false
TRAPPED=false

# ==============================================================================
# UTILITY
# ==============================================================================

# ------------------------------------------------------------------------------
# Displays a simple program header
#
# Arguments:
#   None
# Returns:
#   None
# ------------------------------------------------------------------------------
display_banner() {
    echo '---------------------------------------------------------'
    echo 'Community Hass.io Add-ons: Hass.io cross platform builder'
    echo '---------------------------------------------------------'
}

# ------------------------------------------------------------------------------
# Displays a error message and is able to terminate te script execution
#
# Arguments:
#   $1 Error message
#   $2 Exit code, script will continue execution when omitted
# Returns:
#   None
# ------------------------------------------------------------------------------
display_error_message() {
  local status=${1}
  local exitcode=${2:-0}

  echo >&2
  echo " !     ERROR: ${status}"
  echo >&2

  if [[ ${exitcode} -ne 0 ]]; then
    exit "${exitcode}"
  fi
}

# ------------------------------------------------------------------------------
# Displays a notice
#
# Arguments:
#   $* Notice message to display
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
display_notice_message() {
  local status=$*

  echo
  echo "NOTICE: ${status}"
  echo
}

# ------------------------------------------------------------------------------
# Displays a status message
#
# Arguments:
#   $* Status message to display
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
display_status_message() {
  local status=$*

  echo "-----> ${status}"
}

# ------------------------------------------------------------------------------
# Displays the help of this program
#
# Arguments:
#   $1 Exit code
#   $2 Error message
# Returns:
#   None
# ------------------------------------------------------------------------------
display_help () {
    local exit_code=${1:-${EX_OK}}
    local status=${2:-}

    [[ ! -z "${status}" ]] && display_error_message "${status}"

    cat << EOF
Options:

    -h, --help
        Display this help and exit.

    -t, --target <directory>
        The target directory containing the Dockerfile to build.
        Defaults to the current working directory (.).
    
    -r, --repository <url>
        Build using a remote repository.
        Note: use --target to specify a subdirectory within the repository.

    -b, --branch <name>
        When using a remote repository, build this branch.
        Defaults to master.

    ------ Build Architectures ------

    --aarch64
        Build for aarch64 (arm 64 bits) architecture.

    --amd64
        Build for amd64 (intel/amd 64 bits) architecture.

    --armhf
        Build for armhf (arm 32 bits) architecture.

    --i386
        Build for i386 (intel/amd 32 bits) architecture.

    -a, --all
        Build for all architectures.
        Same as --aarch64 --amd64 --armhf --i386.
        If a limited set of supported architectures are defined in
        a configuration file, that list is still honored when using
        this flag.

    ------ Build output ------

    -i, --image <image>
        Specify a name for the output image.
        In case of building an add-on, this will override the name
        as set in the add-on configuration file. Use '{arch}' as an
        placeholder for the architecture name.
        e.g., --image "myname/{arch}-myaddon"

    -l, --tag-latest
        Tag Docker build as latest.

    --tag-test
        Tag Docker build as test.

    -p, --push
        Upload the resulting build to Docker hub.

    ------ Build options ------

    --arg <key> <value>
        Pass additional build arguments into the Docker build.
        This option can be repeated for multiple key/value pairs.

    -c, --no-cache
        Disable build from cache.

    -s, --single
        Do not parallelize builds. Build one architecture at the time.

    -q, --no-squash
        Do not squash the layers of the resulting image.

    ------ Build meta data ------

    --type <type>
        The type of the thing you are building.
        Valid values are: addon, base, cluster, homeassistant and supervisor.
        If you are unsure, then you probably don't need this flag.
        Defaults to auto detect, with failover to 'addon'.

EOF

    exit "${exit_code}"
}

# ==============================================================================
# SCRIPT LOGIC
# ==============================================================================

# ------------------------------------------------------------------------------
# Cleanup function after execution is of the script is stopped. (trap)
#
# Arguments:
#   $1 Exit code
# Returns:
#   None
# ------------------------------------------------------------------------------
cleanup_on_exit() {
    local exit_code=${1}

    # Prevent double cleanup. Thx Bash :)
    if [[ "${TRAPPED}" != true ]]; then
        TRAPPED=true
        docker_stop_daemon
        docker_disable_crosscompile
    fi

    exit "${exit_code}"
}

# ------------------------------------------------------------------------------
# Clones a remote Git repository to a local working dir
#
# Arguments:
#   None
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
clone_repository() {
    display_status_message 'Cloning remote Git repository'

    [[ "$(ls -A ".")" ]] && display_error_message \
        '/docker mount is in use already, while requesting a repository' \
        "${EX_NOT_EMPTY}"

    git clone \
        --depth 1 --single-branch "${BUILD_REPOSITORY}" \
        -b "${BUILD_BRANCH}" "$(pwd)" \
        || display_error_message 'Failed cloning requested Git repository' \
            "${EX_GIT_CLONE}"

    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Start the Docker build
#
# Arguments:
#   $1 Architecture to build
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
docker_build() {
    local -a build_args
    local arch=${1}
    local build_date
    local dockerfile
    local image

    display_status_message 'Running Docker build'

    dockerfile="${DOCKERFILE//\{arch\}/${arch}}"
    image="${BUILD_IMAGE//\{arch\}/${arch}}"
    build_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    build_args+=(--pull)
    build_args+=(--compress)
    build_args+=(--tag "${image}:${BUILD_VERSION}")
    build_args+=(--build-arg "BUILD_FROM=${BUILD_ARCHS_FROM[${arch}]}")
    build_args+=(--build-arg "BUILD_REF=${BUILD_REF}")
    build_args+=(--build-arg "BUILD_TYPE=${BUILD_TYPE}")
    build_args+=(--build-arg "BUILD_ARCH=${arch}")
    build_args+=(--build-arg "BUILD_DATE=${build_date}")

    for arg in "${!BUILD_ARGS[@]}"; do
        build_args+=(--build-arg "${arg}=${BUILD_ARGS[$arg]}")
    done
    
    [[ "${DOCKER_SQUASH}" = true ]] && build_args+=(--squash)

    if [[ "${DOCKER_CACHE}" = true ]]; then
        build_args+=(--cache-from "${image}:latest")
    else
        build_args+=(--no-cache)
    fi

    IFS=' '
    echo "docker build ${build_args[*]}"

    (
        docker-context-streamer "${BUILD_TARGET}" <<< "$dockerfile" \
        | docker build "${build_args[@]}" -
    ) || display_error_message 'Docker build failed' "${EX_DOCKER_BUILD}"

    display_status_message 'Docker build finished'
    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Disables Docker's cross compiler features (qemu)
#
# Arguments:
#   None
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
docker_disable_crosscompile() {
    display_status_message 'Disabling cross compile features'

    if [[ -f /proc/sys/fs/binfmt_misc/status ]]; then
        umount binfmt_misc || display_error_message \
            'Failed disabling cross compile features!' "${EX_CROSS}"
    fi

    (
        update-binfmts --disable qemu-arm && \
        update-binfmts --disable qemu-aarch64 
    ) || display_error_message 'Failed disabling cross compile features!' \
        "${EX_CROSS}"
    
    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Enables Docker's cross compiler features (qemu)
#
# Arguments:
#   None
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
docker_enable_crosscompile() {
    display_status_message 'Enabling cross compile features'
    ( 
        mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc && \
        update-binfmts --enable qemu-arm && \
        update-binfmts --enable qemu-aarch64 
    ) || display_error_message 'Failed enabling cross compile features!' \
        "${EX_CROSS}"
    
    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Push Docker build result to DockerHub
#
# Arguments:
#   $1 Architecture
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
docker_push() {
    local arch=${1}
    local image

    image="${BUILD_IMAGE//\{arch\}/${arch}}"

    display_status_message 'Pushing Docker image'
    docker push "${image}:${BUILD_VERSION}" \
        || display_error_message 'Docker push failed' "${EX_DOCKER_PUSH}";
    display_status_message 'Push finished'

    if [[ "${DOCKER_TAG_LATEST}" = true ]]; then
        display_status_message 'Pushing Docker image tagged as latest'

        docker push "${image}:latest" \
            || display_error_message 'Docker push failed' "${EX_DOCKER_PUSH}"

        display_status_message 'Push finished'
    fi

    if [[ "${DOCKER_TAG_TEST}" = true ]]; then
        display_status_message 'Pushing Docker image tagged as test'

        docker push "${image}:test" \
            || display_error_message 'Docker push failed' "${EX_DOCKER_PUSH}"

        display_status_message 'Push finished'
    fi

    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Starts the Docker daemon
#
# Arguments:
#   None
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
docker_start_daemon() {
    local time_start
    local time_end

    display_status_message 'Starting the Docker daemon'

    dockerd --experimental=true > /dev/null 2>&1 &
    DOCKER_PID=$!

    display_status_message 'Waiting for Docker to initialize...'
    time_start=$(date +%s)
    time_end=$(date +%s)
    until docker info >/dev/null 2>&1; do
        if [ $((time_end - time_start)) -le ${DOCKER_TIMEOUT} ]; then
            sleep 1
            time_end=$(date +%s)
        else
            display_error_message \
                'Timeout while waiting for Docker to come up' \
                "${EX_DOCKER_TIMEOUT}"
        fi
    done
    disown
    display_status_message 'Docker is initialized'

    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Stops Docker daemon
#
# Arguments:
#   None
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
docker_stop_daemon() {
    local time_start
    local time_end

    display_status_message 'Stopping the Docker daemon'

    if [[ "${DOCKER_PID}" -ne 0 ]] \
        && kill -0 "${DOCKER_PID}" 2> /dev/null \
    ; then
        kill "${DOCKER_PID}"

        time_start=$(date +%s)
        time_end=$(date +%s)
        while kill -0 "${DOCKER_PID}" 2> /dev/null; do
            if [ $((time_end - time_start)) -le ${DOCKER_TIMEOUT} ]; then
                sleep 1
                time_end=$(date +%s)
            else
                display_error_message \
                    'Timeout while waiting for Docker to shut down' \
                    "${EX_DOCKER_TIMEOUT}"
            fi            
        done

        display_status_message 'Docker daemon has been stopped'
    else
        display_status_message 'Docker daemon was already stopped'
    fi

    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Places 'latest'/'test' tag(s) onto the current build result
#
# Arguments:
#   $1 Architecture
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
docker_tag() {
    local arch=${1}
    local image

    image="${BUILD_IMAGE//\{arch\}/${arch}}"

    if [[ "${DOCKER_TAG_LATEST}" = true ]]; then
        display_status_message 'Tagging images as latest'
        docker tag "${image}:${BUILD_VERSION}" "${image}:latest" \
            || display_error_message 'Setting latest tag failed' \
                "${EX_DOCKER_TAG}"
    fi

    if [[ "${DOCKER_TAG_TEST}" = true ]]; then
        display_status_message 'Tagging images as test'
        docker tag "${image}:${BUILD_VERSION}" "${image}:test" \
            || display_error_message 'Setting test tag failed' \
                "${EX_DOCKER_TAG}"
    fi

    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Try to pull latest version of the current image to use as cache
#
# Arguments:
#   $1 Architecture
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
docker_warmup_cache() {
    local arch=${1}
    local image

    image="${BUILD_IMAGE//\{arch\}/${arch}}"
    display_status_message 'Warming up cache'

    if ! docker pull "${image}:latest" 2>&1; then
        display_notice_message 'Cache warmup failed, continuing without it'
        DOCKER_CACHE=false
    fi

    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Tries to fetch information from the add-on config file.
#
# Arguments:
#   $1 JSON file to parse
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
get_info_json() {
    local archs
    local args
    local jsonfile=$1
    local squash

    display_status_message "Loading information from ${jsonfile}"

    [[ -z "${BUILD_VERSION:-}" ]] \
        && BUILD_VERSION=$(jq -r '.version' "${jsonfile}")

    [[ -z "${BUILD_IMAGE:-}" ]] \
        && BUILD_IMAGE=$(jq -r '.image // empty' "${jsonfile}")

    IFS=
    archs=$(jq -r '.arch // empty | .[]' "${jsonfile}")
    while read -r arch; do
        SUPPORTED_ARCHS+=("${arch}")
    done <<< "${archs}"

    IFS=
    archs=$(jq -r '.build_from // empty | keys[]' "${jsonfile}")
    while read -r arch; do
        if [[ ! -z "${arch}"
            && -z "${BUILD_ARCHS_FROM["${arch}"]:-}"
        ]]; then
            BUILD_ARCHS_FROM[${arch}]=$(jq -r \
                ".build_from | .${arch}" "${jsonfile}")
        fi
    done <<< "${archs}"
    
    squash=$(jq -r '.squash // empty' "${jsonfile}")
    [[ "${squash}" = "true" ]] && DOCKER_SQUASH=true
    [[ "${squash}" = "false" ]] && DOCKER_SQUASH=false

    IFS=
    args=$(jq -r '.args // empty | keys[]' "${jsonfile}")
    while read -r arg; do
        if [[ ! -z "${arg}"
            && -z "${BUILD_ARGS["${arch}"]:-}"
        ]]; then
            BUILD_ARGS[${arg}]=$(jq -r \
                ".args | .${arg}" "${jsonfile}")
        fi
    done <<< "${args}"        

    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Tries to fetch information from existing Dockerfile
#
# Arguments:
#   None
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
get_info_dockerfile() {
    local labels
    local json

    display_status_message 'Collecting information from Dockerfile'

    DOCKERFILE=$(<"${BUILD_TARGET}/Dockerfile")
    json=$(dockerfile2json "${BUILD_TARGET}/Dockerfile")

    if [[ 
        ! -z $(jq -r '.[] | select(.cmd=="label") // empty' <<< "${json}")
    ]]; then
        labels=$(jq -r '.[] | select(.cmd=="label") | .value | .[]' \
                    <<< "${json}")
        IFS=
        while read -r label; do
            read -r value
            value="${value%\"}"
            value="${value#\"}"
            EXISTING_LABELS+=("${label}")

            case ${label} in
                io.hass.type)
                    [[ -z "${BUILD_TYPE:-}" ]] && BUILD_TYPE="${value}"
                    ;;
            esac
        done <<< "${labels}"
    fi

    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Tries to fetch information from the Git repository
#
# Arguments:
#   None
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
get_info_git() {
    display_status_message 'Collecting information from Git'

    # Is this even a Git repository?
    if ! git -C . rev-parse; then
        display_notice_message 'This does not Git repository. Skipping.'
        return "${EX_NOT_GIT}"
    fi

    # Is the Git repository dirty? (Uncomitted changes in repository)
    if [[ -z "$(git status --porcelain)" ]]; then
        BUILD_REF=$(git rev-parse --short HEAD)
    else
        BUILD_REF="dirty"
    fi

    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Parse CLI arguments
#
# Arguments:
#   None
# Returns:
#   None
# ------------------------------------------------------------------------------
parse_cli_arguments() {
    while [[ $# -gt 0 ]]; do
        case ${1} in
            -h|--help)
                display_help
                ;;
            --aarch64)
                BUILD_ARCHS+=(aarch64)
                ;;
            --amd64)
                BUILD_ARCHS+=(amd64)
                ;;
            --armhf)
                BUILD_ARCHS+=(armhf)
                ;;
            --i386)
                BUILD_ARCHS+=(i386)
                ;;
            --all)
                BUILD_ALL=true
                ;;
            -i|--image)
                BUILD_IMAGE=${2}
                shift
                ;;
            -l|--tag-latest)
                DOCKER_TAG_LATEST=true
                ;;
            --tag-test)
                DOCKER_TAG_TEST=true
                ;;
            -p|--push)
                DOCKER_PUSH=true
                ;;
            -n|--no-cache) 
                DOCKER_CACHE=false
                ;;
            -q|--no-squash)
                DOCKER_SQUASH=false
                ;;
            -s|--single)
                BUILD_PARALLEL=false
                ;;
            --type)
                BUILD_TYPE=${2}
                shift
                ;;
            -t|--target)
                BUILD_TARGET=${2}
                shift
                ;;
            -r|--repository)
                BUILD_REPOSITORY=${2}
                shift
                ;;
            -v|--version)
                BUILD_VERSION=${2}
                shift
                ;;
            -b|--branch)
                BUILD_BRANCH=${2}
                shift
                ;;
            --arg)
                BUILD_ARGS[${2}]=${3}
                shift
                shift
                ;;
            *)
                display_help "${EX_UNKNOWN}" "Argument '${1}' unknown."
                ;;
        esac
        shift
    done
}

# ------------------------------------------------------------------------------
# Ensures we have all the information we need to continue building
#
# Arguments:
#   None
# Returns:
#   None
# ------------------------------------------------------------------------------
preflight_checks() {

    display_status_message 'Running preflight checks'

    # Deal breakers
    if ip link add dummy0 type dummy > /dev/null; then
        ip link delete dummy0 > /dev/null
    else
        display_error_message \
            'This build enviroment needs extended privileges (--privileged)' \
            "${EX_PRIVILEGES}"
    fi

    [[ ${#BUILD_ARCHS[@]} -eq 0 ]] && [[ "${BUILD_ALL}" = false ]] \
        && display_help "${EX_NO_ARCHS}" 'No architectures to build'

    [[ -z "${BUILD_VERSION:-}" ]] && display_error_message \
        'No version found and specified. Please use --version' "${EX_VERSION}"

    if [[ ${#BUILD_ARCHS[@]} -ne 0 ]] \
        && [[ "${BUILD_ALL}" = false ]] \
        && [[ ! -z "${SUPPORTED_ARCHS[*]:-}" ]]; 
    then
        for arch in "${BUILD_ARCHS[@]}"; do
            [[ "${SUPPORTED_ARCHS[*]}" = *"${arch}"* ]] || \
                display_error_message \
                    "Requested to build for ${arch}, but it seems like it is not supported" \
                    "${EX_SUPPORTED}"
        done
    fi

    for arch in "${SUPPORTED_ARCHS[@]}"; do
        [[ ! -z $arch && -z "${BUILD_ARCHS_FROM[${arch}]:-}" ]] \
            && display_error_message \
                "Architucure ${arch}, is missing a image to build from" \
                "${EX_NO_FROM}"
    done

    [[ $(awk '/^FROM/{a++}END{print a}' <<< "${DOCKERFILE}") -le 1 ]] || \
        display_error_message 'The Dockerfile seems to be multistage!' \
        "${EX_MULTISTAGE}"

    [[ -z "${BUILD_IMAGE:-}" ]] \
        && display_help "${EX_NO_IMAGE_NAME}" 'Missing build image name'

    [[ 
        "${BUILD_TYPE:-}" =~ ^(|addon|base|cluster|homeassistant|supervisor)$
    ]] || \
        display_help "$EX_INVALID_TYPE" "${BUILD_TYPE:-} is not a valid type."
    
    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Prepares all variables for building use
#
# Arguments:
#   None
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
prepare_defaults() {

    display_status_message 'Filling in configuration gaps with defaults'

    [[ -z "${SUPPORTED_ARCHS[*]:-}" ]] \
        && SUPPORTED_ARCHS=(aarch64 amd64 armhf i386)

    if [[ "${BUILD_ALL}" = true ]]; then
        IFS=' '
        BUILD_ARCHS=(${SUPPORTED_ARCHS[*]});
    fi

    [[ -z "${BUILD_REF:-}" ]] && BUILD_REF='Unknown'
    [[ -z "${BUILD_TYPE:-}" ]] && BUILD_TYPE='addon'

    return "${EX_OK}"
}

# ------------------------------------------------------------------------------
# Preparse the Dockerfile for build use
#
# This is mainly to maintain some form of backwards compatibility
#
# Arguments:
#   None
# Returns:
#   Exit code
# ------------------------------------------------------------------------------
prepare_dockerfile() {
    local -a labels

    display_status_message 'Preparing Dockerfile for use'

    # Ensure Dockerfile ends with a empty line
    DOCKERFILE+=$'\n'

    [[ ! "${EXISTING_LABELS[*]:-}" = *"io.hass.type"* ]] \
        && labels+=("io.hass.type=${BUILD_TYPE}")
    [[ ! "${EXISTING_LABELS[*]:-}" = *"io.hass.version"* ]] \
        && labels+=("io.hass.version=${BUILD_VERSION}")
    [[ ! "${EXISTING_LABELS[*]:-}" = *"io.hass.arch"* ]] \
        && labels+=("io.hass.arch=${BUILD_ARCH}")

    if [[ ! -z "${labels[*]:-}" ]]; then
        IFS=" "
        DOCKERFILE+="LABEL ${labels[*]}"$'\n'
    fi

    return "${EX_OK}"
}

# ==============================================================================
# RUN LOGIC
# ------------------------------------------------------------------------------
main() {
    trap 'cleanup_on_exit $?' EXIT SIGINT SIGTERM

    # Parse input
    display_banner
    parse_cli_arguments "$@"

    # Download source (if requested)
    [[ ! -z "${BUILD_REPOSITORY:-}" ]] && clone_repository

    # This might be an issue...
    [[ -f "${BUILD_TARGET}/Dockerfile" ]] \
        || display_error_message 'Dockerfile not found?' "${EX_DOCKERFILE}"

    # Gather build information
    [[ -f "${BUILD_TARGET}/config.json" ]] \
        && get_info_json "${BUILD_TARGET}/config.json"
    [[ -f "${BUILD_TARGET}/build.json" ]] \
        && get_info_json "${BUILD_TARGET}/build.json"
    get_info_git
    get_info_dockerfile

    # Getting ready
    prepare_defaults
    preflight_checks
    prepare_dockerfile

    # Docker daemon startup
    docker_enable_crosscompile
    docker_start_daemon

    # Cache warming
    display_status_message 'Warming up cache for all requested architectures'
    if [[ "${DOCKER_CACHE}" = true ]]; then
        for arch in "${BUILD_ARCHS[@]}"; do
            (docker_warmup_cache "${arch}" | sed "s/^/[${arch}] /") &
        done
    fi
    wait
    display_status_message 'Warmup for all requested architectures finished'

    # Building!
    display_status_message 'Starting build of all requested architectures'
    if [[ "${BUILD_PARALLEL}" = true ]]; then
        for arch in "${BUILD_ARCHS[@]}"; do
            docker_build "${arch}" | sed "s/^/[${arch}] /" &
        done
        wait
    else
        for arch in "${BUILD_ARCHS[@]}"; do
            docker_build "${arch}" | sed "s/^/[${arch}] /"
        done
    fi  
    display_status_message 'Build of all requested architectures finished'

    # Tag it
    display_status_message 'Tagging Docker images'
    for arch in "${BUILD_ARCHS[@]}"; do
        docker_tag "${arch}" | sed "s/^/[${arch}] /" &
    done
    wait

    # Push it
    if [[ "${DOCKER_PUSH}" = true ]]; then
        display_status_message 'Pushing all Docker images'
        for arch in "${BUILD_ARCHS[@]}"; do
            docker_push "${arch}" | sed  "s/^/[${arch}] /" &
            done
        wait
        display_status_message 'Pushing of all Docker images finished'
    fi

    # Fin
    exit "${EX_OK}"
}
main "$@"
