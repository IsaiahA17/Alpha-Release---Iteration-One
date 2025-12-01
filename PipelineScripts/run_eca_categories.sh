#!/bin/bash
"/home/nash/Sikraken/SikrakenDevSpace/bin/test_category_sikraken.sh" "/home/nash/sv-benchmarks/c" ECA 8 10 debug -no_testcov -ss 3 #Using command for running against ECA categories
cd /home/nash/PipelineScripts/SikrakenDevSpace/categories/ECA
recent_ECA_folder=$(ls -d */ | sort -t_ -k2,2 -k3,3 -k4,4 -r | head -n 1) #Getting most recent folder in ECA folder

TARGET_BASE="/home/nash/PipelineScripts/SikrakenDevSpace/categories/ECA/$recent_ECA_folder"
SOURCE_BASE="/home/nash/Sikraken/sikraken_output"

for d in "$TARGET_BASE"/*/; do
    name=$(basename "$d")
    src_file="$SOURCE_BASE/$name/$name.i"
    if [[ -f "$src_file" ]]; then
        cp "$src_file" "$d"
        echo "Moved $src_file → $d"
    else
        echo "Missing: $src_file"
    fi
done

echo "Processing /home/nash/PipelineScripts/SikrakenDevSpace/categories/ECA/$recent_ECA_folder for S3" 
python3 "/home/nash/SikrakenPythonScripts/filepath_to_url_processor.py" "/home/nash/PipelineScripts/SikrakenDevSpace/categories/ECA/$recent_ECA_folder" #Converting file paths to S3 urls
echo "Placing .i files in ECA For Viewing in HTML report"

echo "Outputting $recent_ECA_folder to S3"
aws s3 sync "$recent_ECA_folder" "s3://testcov-results-bucket/$recent_ECA_folder"
