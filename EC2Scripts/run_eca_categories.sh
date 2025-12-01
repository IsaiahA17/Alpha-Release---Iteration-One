#!/bin/bash

#Getting command line arguments
category="$1"
cores="$2"
budget="$3"
mode="$4"
testcov_switch="$5"
stack_size="$6"

#Running test_category_sikraken.sh along with command line arguments
"/home/ubuntu/Sikraken/SikrakenDevSpace/bin/test_category_sikraken.sh" "/home/ubuntu/sv-benchmarks/c" "$1" "$2" "$3" "$4" "$5" "$6"

cd /home/ubuntu/SikrakenDevSpace/categories/ECA #Moving to ECA folder 

# Get most recent ECA folder -ls -d */ lists only directories using */ to match as directories end with /, 
# sort -t_ will take the different numbers used in the folder name, seperated by the "_" and then -r reverses the sorting order from ascending to descending
# head -n 1 takes the first result of the sorted list as the pipe symbol causes the outputs of each command to be the input for the next 
recent_ECA_folder=$(ls -d */ | sort -t_ -k2,2 -k3,3 -k4,4 -r | head -n 1)

TARGET_BASE="/home/ubuntu/SikrakenDevSpace/categories/ECA/$recent_ECA_folder" #Setting path for new eca folder
SOURCE_BASE="/home/ubuntu/Sikraken/sikraken_output" #Setting path for Sikraken's output 

# Copy .i files into their corresponding problem folders
for d in "$TARGET_BASE"/*/; do #for each directory, get the .i and move it to the recently made ECA folder
    name=$(basename "$d")  
    src_file="$SOURCE_BASE/$name/$name.i" #Name of .i file is the same as its parent directory so finding it based on that 
    if [[ -f "$src_file" ]]; then
        cp "$src_file" "$d"
        echo "Moved $src_file → $d"
    else
        echo "Missing: $src_file"
    fi
done

echo "Processing $TARGET_BASE for S3"

#Processing the file paths in the .html report to be the S3 URL instead
python3 "/home/ubuntu/SikrakenDevOps/SikrakenPythonScripts/filepath_to_url_processor.py" "$TARGET_BASE" --run_folder "$recent_ECA_folder" 

echo "Outputting $recent_ECA_folder to S3" #Outputting the folder to S3 bucket
aws s3 sync "$TARGET_BASE" "s3://testcov-results-bucket/$recent_ECA_folder"
