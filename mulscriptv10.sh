#!/bin/bash

# ---- INITIAL SETUP ----
#source links
#OCP3 270: docker-registry-default.roanprd-openshift.intra.absa.co.za
#OCP3 SDC: docker-registry-default.roaprd-openshift.intra.absa.co.za
#OKD 270: default-route-openshift-image-registry.apps.aroocp-lunar.intra.absa.co.za
#OKD SDC: 
#OCP4 270: default-route-openshift-image-registry.apps.ocp-aronprd.intra.absa.co.za
#OCP4 SDC: default-route-openshift-image-registry.apps.ocp-aroprd.intra.absa.co.za

# Base URLs for source and destination registries
source_login_registry="default-route-openshift-image-registry.apps.ocp-aronprd.intra.absa.co.za"
destination_login_registry="registry-quay-global-registry.apps.ocp-aronprd.intra.absa.co.za"

# Group names for source and destination registries
#NAMESPACES=("namespace1" "namespace2")
NAMESPACES=("aro-chat-prod")
destination_group="aro-group"

success_log="success_log.txt"
failure_log="failure_log.txt"

> $failure_log

# ---- UTILITY FUNCTIONS ----

repo_exists() {
    local quay_token="$1"
    local repo_name="$2"
    response=$(curl -s -X GET \
            -H "Authorization: Bearer $quay_token" \
            $destination_login_registry/api/v1/repository/$repo_name)

    [[ $response != *'"status": "not found"'* ]]
}

create_quay_repo() {
    local quay_token="$1"
    local repo_name="$2"

    if ! repo_exists "$quay_token" "$repo_name"; then
        curl -s -X POST \
             -H "Authorization: Bearer $quay_token" \
             -H "Content-Type: application/json" \
             -d "{ \"namespace\": \"$destination_group\", \"repo_kind\": \"image\", \"visibility\": \"private\" }" \
             $destination_login_registry/api/v1/repository/$repo_name
    fi
}

push_image() {
    local source_image="$1"
    local destination_image="$2"
    #local source_token="$3"

    if grep -q "$source_image" $success_log; then
        echo "$source_image already migrated successfully. Skipping."
        return 0
    fi

    if podman pull "$source_image" --tls-verify=false; then
        #podman tag "$source_image" "$destination_image"
        if podman push "$destination_image" --tls-verify=false; then
            echo "$source_image was migrated successfully." | tee -a $success_log
            podman rmi "$source_image" "$destination_image"
            return 0
        fi
    fi
    echo "$source_image migration failed." | tee -a $failure_log
    return 1
}

# ---- OPENSHIFT LOGIN ----

read -p "Please provide the OpenShift API endpoint: " OC_ENDPOINT
read -p "Please provide your OpenShift username: " OC_USERNAME
read -s -p "Please provide your OpenShift password: " OC_PASSWORD
echo

if ! oc login "$OC_ENDPOINT" --username="$OC_USERNAME" --password="$OC_PASSWORD" --insecure-skip-tls-verify=true; then
    echo "Error: Failed to log into OpenShift."
    exit 1
fi

read -p "Please specify the number of the latest tags to migrate (e.g., 2) or type 'all' to migrate all: " LATEST_TAGS_COUNT

declare -a namespace_summary

> imagepairs.txt

for source_group in "${NAMESPACES[@]}"; do
    images=$(oc get is -n $source_group -o jsonpath="{.items[*].metadata.name}")
    
    if [[ "$LATEST_TAGS_COUNT" == "all" ]]; then
        total_tags_count=0
        for image in $images; do
            tags=$(oc get is $image -n $source_group -o jsonpath='{.status.tags[*].tag}')
            if [ -z "$tags" ]; then
            echo "$source_login_registry/$source_group/$image has no tags. Logging to failures." | tee -a $failure_log
            continue
            fi
            tags_array=($tags)
            total_tags_count=$((total_tags_count + ${#tags_array[@]}))
            
            for tag in $tags; do
                echo "$source_login_registry/$source_group/$image:$tag $destination_login_registry/$destination_group/$source_group/$image:$tag" >> imagepairs.txt
            done
        done
    else
        total_tags_count=0
        for image in $images; do
            tags=$(oc get is $image -n $source_group -o json | jq -r '.status.tags[]? | select(.items[0]?.created) | [.tag, .items[0].created] | @tsv' | sort -k2 -r | head -n $LATEST_TAGS_COUNT | cut -f1)
            if [ -z "$tags" ]; then
            echo "$source_login_registry/$source_group/$image has no tags. Logging to failures." | tee -a $failure_log
            continue
            fi
            tags_array=($tags)
            total_tags_count=$((total_tags_count + ${#tags_array[@]}))
            
            for tag in $tags; do
                echo "$source_login_registry/$source_group/$image:$tag $destination_login_registry/$destination_group/$source_group/$image:$tag" >> imagepairs.txt
            done
        done
    fi

    namespace_info="$source_group $(echo "$images" | wc -w) $total_tags_count"
    namespace_summary+=("$namespace_info")
done

echo "------------------------------------------------"
echo "Namespace      | Image Count | Tag Count"
echo "------------------------------------------------"
for info in "${namespace_summary[@]}"; do
    IFS=' ' read -r namespace img_count tag_count <<< "$info"
    echo "$namespace | $img_count  | $tag_count"
done
echo "------------------------------------------------"

read -s -p "Please provide the token for the source registry: " SOURCE_TOKEN
echo
read -p "Please provide the username for the destination registry: " DESTINATION_USERNAME
read -s -p "Please provide the password for the destination registry: " DESTINATION_PASSWORD
echo

podman login -p $SOURCE_TOKEN -u unused "$source_login_registry" --tls-verify=false
podman login -u "$DESTINATION_USERNAME" -p "$DESTINATION_PASSWORD" "$destination_login_registry" --tls-verify=false

while IFS= read -r line; do
    source_image_name=$(echo "$line" | awk '{print $1}')
    destination_image_name=$(echo "$line" | awk '{print $2}')

    create_quay_repo "$DESTINATION_PASSWORD" "${destination_image_name%%:*}"
    push_image "$source_image_name" "$destination_image_name"
    #push_image "$source_image_name" "$destination_image_name" "$SOURCE_TOKEN"
done < imagepairs.txt

success_count=$(cat $success_log | wc -l)
failure_count=$(cat $failure_log | wc -l)

echo "Migration completed. $success_count images migrated successfully. $failure_count images failed to migrate."
