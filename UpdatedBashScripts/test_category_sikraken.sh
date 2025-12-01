#!/bin/bash
#
# Script: test_category_sikraken.sh
# Author: Chris Meudec
# Started: May 2025 (Major update: Oct 2025 for parallel error handling)
# Category Reporting Flow Diagram: https://docs.google.com/drawings/d/1wsCvXsDvS5q7mXy-JMwdL5wQLjxB3pQzcYdrktbfE8Q/edit?usp=sharing
# Description: Run all the benchmarks in a TestComp category as defined in the <category>.set file in parallel
# The <category>.set file are in sv-benchmarks/c directory or can be user-defined
# Outputs logs files in SikrakenDevSpace/categories/<category>/<timestamp>/
# Takes into account possible exclude set for ECA
# For each benchmark: generate tests, then generate a runtime graph using the create_runtime_graph.sh script
# Then call TestCov on the all benchmarks using the helper test_category_testcov.sh script
# Generates a summary table for the entire category using the helper create_category_test_run_table.sh script
# Updates the category summary table for all the previous runs

# Plays a sound at the end of the run
# Example: ./SikrakenDevSpace/bin/test_category_sikraken.sh /home/chris/sv-benchmarks/c ECA 8 30 debug -ss 5



clear
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" 
SIKRAKEN_INSTALL_DIR="$SCRIPT_DIR/../../"
YL="33m"    # yellow
script_name=$(basename "$0")

echo "Run all the benchmarks from a TestComp category using SIKRAKEN_INSTALL_DIR=$SIKRAKEN_INSTALL_DIR"

# --- GLOBAL ERROR FLAG FOR PARALLEL EXECUTION ---
# Using a unique name to prevent collision if two different scripts are running simultaneously
PARALLEL_FAIL_FLAG="$SIKRAKEN_INSTALL_DIR/parallel_test_category_fail.log" 

# --- Check minimum args ---
# Allow up to 8 arguments: 5 required + 3 optional (-scg, -no_testcov, -ss VALUE)
if [ $# -lt 5 ] || [ $# -gt 8 ]; then
    echo "Sikraken ERROR from $script_name:"
    echo "Usage: $script_name <path_to_category> <category> <cores> <budget> <mode> [OPTIONS]"
    echo "Options: [-scg] [-no_testcov] [-ss STACK_SIZE in GB]"
    exit 1
fi

# --- Required arguments ---
path_to_category="$1"   # e.g. /home/chris/sv-benchmarks/c
category="$2"           # e.g. ECA
cores="$3"              # e.g. 6
budget="$4"             # e.g. 900
mode="$5"               # e.g. debug or release

# --- Initialize Optional Variables ---
shortcutgen=""
shortcutgen_flag=0
no_testcov=0
# ECLiPSe use binary base for stack sizes (KiB, MiB, Gib). The command line only accepts decimal stack size sizes (GB)
# so for accuracy  we assume a stack size on the command line in GB and convert to MiB for ECLiPse
stack_size_value="$(( 3 * 953 ))M"    #default stack size is 3 GB roughly 3 * 953 MiB

# --- Process Optional Arguments (Shift and Loop) ---
shift 5
while [ "$#" -gt 0 ]; do
    option="$1"
    case "$option" in
        "-scg")
            shortcutgen=", shortcut_gen"
            shortcutgen_flag=1
            shift 1
            ;;
        "-no_testcov")
            no_testcov=1
            shift 1
            ;;
        "-ss")
            # Check if the next argument (the value) exists
            if [ -z "$2" ]; then
                echo "Sikraken ERROR from $script_name: Option -ss requires an argument (STACK_SIZE) in GB."
                exit 1
            fi
            
            # Check if the next argument is a positive integer
            if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -le 0 ]; then
                echo "Sikraken ERROR from $script_name: STACK_SIZE for -ss must be a positive integer."
                exit 1
            fi
            
            stack_size_value="$(( $2 * 953 ))M"
            shift 2 # Consume both the '-ss' flag and the VALUE
            ;;
        *)
            # Handle unknown options
            echo "Sikraken ERROR from $script_name: Unknown option: $option"
            echo "Usage: $script_name <path_to_category> <category> <cores> <budget> <mode> [OPTIONS]"
            echo "Options: [-scg] [-no_testcov] [-ss STACK_SIZE]"
            exit 1
            ;;
    esac
done

# --- Debug info ---
echo "path_to_category = $path_to_category"
echo "category           = $category"
echo "cores              = $cores"
echo "budget             = $budget"
echo "mode               = $mode"
echo "shortcutgen        = $shortcutgen"
echo "no_testcov         = $no_testcov"

# Check if the path_to_category exists
if [ ! -d "$path_to_category" ]; then
    echo "Sikraken ERROR from $script_name: the passed path to category $path_to_category does not exist."
    exit 1
fi

category_file="$category".set   #input file describing the category
full_path_to_category_file="$path_to_category/$category_file"

# Check if the category file exists
if [ ! -f "$full_path_to_category_file" ]; then
    echo "Sikraken ERROR from $script_name: the file of categories $category_file does not exist in $path_to_category"
    exit 1
fi
# Define exclusion set for ECA
exclude_set=""
if [ $category == "ECA" ]; then
    exclude_set="$SCRIPT_DIR/../ECA-excludes.set"
    if [ ! -f "$exclude_set" ]; then
        echo "Sikraken ERROR from $script_name: Exclusion set $exclude_set does not exist."
        exit 1
    fi
    echo "Sikraken $script_name log: Using the exclude set: "$exclude_set""
fi

echo "Sikraken $script_name log: called: "$script_name $@""

# re-compile the parser in case it changed during development
/home/nash/Sikraken/bin/compile_parser.sh
#/bin/compile_parser.sh
if [ $? -ne 0 ]; then
    echo "Sikraken ERROR from $script_name: ERROR: Sikraken parser recompilation failed"
    exit 1
else
    echo "Sikraken $script_name log: Sikraken parser successfully recompiled"
fi

timestamp=$(date +"%Y_%m_%d_%H_%M")
output_dir="./SikrakenDevSpace/categories/$category/$timestamp"
echo "The output dir is $output_dir"
mkdir -p "$output_dir"

# --- CLEANUP GLOBAL FAILURE FLAG ---
if [ -f "$PARALLEL_FAIL_FLAG" ]; then
    rm -f "$PARALLEL_FAIL_FLAG"
fi

# Job pool to limit the number of background processes
job_pool() {
    while [ "$(jobs -r | wc -l)" -ge "$cores" ]; do
        sleep 1  # Wait for an available slot
    done
}

# generate_tests_and_call_testcov runs in a background subshell. Errors must be logged to a global file 
# and terminated with 'return 1' instead of 'exit 1'.
generate_tests_and_call_testcov() {
    local benchmark="$1"
    local gcc_flag="$2"
    local testcov_data_model="$3"

    # Extract the basename of the file (without the path nor extension)
    local basename=$(basename "$benchmark")
    basename="${basename%.*}"
    local dirname=$(dirname "$benchmark")
    local benchmark_output_dir="$output_dir"/"$basename"
    mkdir -p "$benchmark_output_dir"
    
    local parsed_dir="$SIKRAKEN_INSTALL_DIR/sikraken_output/$basename"
    mkdir -p $parsed_dir

    # Check the file extension
    file_extension="${benchmark##*.}"
    if [ "$file_extension" == "i" ]; then
        # If the file is already preprocessed (.i), just copy it to $output_dir
        cp "$benchmark" "$parsed_dir/"
        if [ $? -ne 0 ]; then
            echo "Sikraken ERROR from $script_name: Failed to copy $benchmark to $parsed_dir"
            echo "Sikraken PARALLEL ERROR: Failed to copy $benchmark" >> "$PARALLEL_FAIL_FLAG"
            return 1 # Terminate the subshell
        fi
    else
        # If the file is not preprocessed, preprocess it with gcc
        gcc -E -P "$benchmark" $gcc_flag -o "$parsed_dir/$basename.i"
        if [ $? -ne 0 ]; then
            echo "Sikraken ERROR from $script_name: gcc failed on gcc -E -P "$benchmark" $gcc_flag -o "$parsed_dir/$basename.i""
            echo "Sikraken PARALLEL ERROR: gcc failed on $benchmark" >> "$PARALLEL_FAIL_FLAG"
            return 1 # Terminate the subshell
        fi
    fi

    # Run the parser on foo.i
    $SIKRAKEN_INSTALL_DIR/bin/sikraken_parser.exe $gcc_flag -p$parsed_dir $basename
    # Note: If sikraken_parser.exe fails here, the error will be caught by the subsequent eclipse_call failure if it relies on the parsed output.

    echo -e "Sikraken $script_name log: Generating tests for $basename using a budget of $budget seconds"

    # Generate test inputs
    local eclipse_call="$SIKRAKEN_INSTALL_DIR/eclipse/bin/x86_64_linux/eclipse -f $SIKRAKEN_INSTALL_DIR/SymbolicExecutor/se_main.pl -e \"se_main(['$SIKRAKEN_INSTALL_DIR', '${SIKRAKEN_INSTALL_DIR}/${rel_path_c_file}', '$basename', main, $mode, testcomp, '$gcc_flag', budget($budget) $shortcutgen])\" -g $stack_size_value -l 1G"
    local sikraken_log="$benchmark_output_dir/sikraken.log" 
    local timeout_duration=60
    eval timeout $timeout_duration $eclipse_call  >> $sikraken_log 2>&1
    timeout_status=$?

    if [ $timeout_status -eq 124 ]; then
        echo "Sikraken ERROR: ECLiPSe process timed out after $timeout_duration seconds" >> $sikraken_log
        echo "Sikraken PARALLEL ERROR: ECLiPSe timed out for $basename" >> "$PARALLEL_FAIL_FLAG"
        return 1
    elif [ $? -ne 0 ]; then
        echo "Sikraken ERROR from $script_name: Call to ECLiPSe $eclipse_call failed"
        echo "Sikraken PARALLEL ERROR: ECLiPSe call failed for $basename" >> "$PARALLEL_FAIL_FLAG"
        echo "Exit status: $?"
        # Sikraken ended abnormally, but may still have produced tests that need graphed and executed
    else
        echo "Sikraken $script_name log: Test inputs generated for "$basename" using $eclipse_call"
    fi

    #generate graph of timings
    $SIKRAKEN_INSTALL_DIR/SikrakenDevSpace/bin/helper/create_runtime_graph.sh "$sikraken_log"

    #generate highlighted HTML C code with missing coverage
    $SIKRAKEN_INSTALL_DIR/SikrakenDevSpace/bin/helper/highlight_branches.sh "$sikraken_log" "$parsed_dir/$basename.pl" "$benchmark_output_dir/$basename.html"

    if (( no_testcov == 1 )); then
        echo -e "\e["$YL"Skipping TestCov: relying on Sikraken coverage\e[0m"
    else
        echo -e "\e[34mCalling Testcov...\e[0m"
        testcov_call="$SIKRAKEN_INSTALL_DIR/bin/run_testcov.sh"   # program
        testcov_args=( "$benchmark" "$testcov_data_model" )      # args as array
        echo -e "\e[34mCalling Testcov using: $testcov_call ${testcov_args[*]}\e[0m"

        # run it without eval, preserving arguments and quoting
        "$testcov_call" "${testcov_args[@]}" >"$benchmark_output_dir/testcov_call.log" 2>&1

        echo -e "\e[32mEnded TestCov for $basename\e[0m"
    fi
}

### MAIN starts here
start_wall_time=$(date +"%Y-%m-%d %H:%M:%S")    # Capture human-readable time and Unix timestamp for start
start_ts=$(date +%s)

category_extracted_benchmarks_files=$"$output_dir"/benchmark_files.txt  #output list of benchamrks for the category
log_file=$"$output_dir"/category_test_run.log
echo "Command Used to Generate the Category Test run: $0 $@" >> $log_file
echo "Timestamp: $timestamp" >> $log_file
echo "Category: $category" >> $log_file
echo "Mode: $mode" >> $log_file
echo "Budget: $budget" >> $log_file
echo "Cores: $cores" >> $log_file
echo "Options: shortcutgen: $shortcutgen_flag, no_testcov: $no_testcov" >> $log_file
while read -r pattern_benchmark_directory; do
    
    # e.g. for all the *.yml matching pattern_benchmark_directory eca-rers2012/*.yml
    for yml_file in $path_to_category/$pattern_benchmark_directory; do
        # Exclude files listed in the exclusion set
        if [ -n "$exclude_set" ] && grep -Fxq "$yml_file" "$exclude_set"; then
            # echo "Sikraken $script_name log: skipping excluded file: $yml_file"
            continue
        fi
        echo "yml_file is $yml_file"
        if [ -f "$yml_file" ]; then
            # Check if the file contains the required property_file line
            if grep -qE "^\s*- property_file: \.\./properties/coverage-branches\.prp$" "$yml_file"; then
                echo "Sikraken $script_name log: extracting benchmark file from $yml_file"

                # Extract the input file (match "input_files: <filename>" for .c or .i files)
                benchmark=$(grep "input_files:" "$yml_file" | sed -n "s/^[[:space:]]*input_files:[[:space:]]*\(['\"]\?\)\(.*\)\1/\2/p")

                # Extract the data model
                data_model=$(grep "data_model:" "$yml_file" | sed -n "s/^[[:space:]]*data_model:[[:space:]]*\(.*\)/\1/p")

                # Generate GCC flag based on the value of data_model
                if [ "$data_model" == "ILP32" ]; then
                    gcc_flag="-m32"
                    testcov_data_model="-32"
                elif [ "$data_model" == "LP64" ]; then
                    gcc_flag="-m64"
                    testcov_data_model="-64"
                else
                    echo "Sikraken ERROR from $script_name: unsupported data model: $data_model"
                    # CRITICAL ERROR IN MAIN LOOP: Exit immediately
                    exit 1
                fi
                full_path_benchmark_file="$(dirname $yml_file)/$benchmark"
                # write each file in the benchmark category into $category_extracted_benchmarks_files used for table generation
                echo "$full_path_benchmark_file $testcov_data_model" >> $category_extracted_benchmarks_files

                job_pool  # Wait for an available slot
            
                generate_tests_and_call_testcov "$full_path_benchmark_file" "$gcc_flag" "$testcov_data_model" &  # Run in the background
            fi  # if the .yml file does not contain the correct property, it is silently skipped
        fi
    done #no more *.yml file
done < <(grep -o '.*\/.*\.yml' "$full_path_to_category_file")

wait    # Wait for all background jobs to finish

# --- CHECK FOR PARALLEL ERRORS HERE ---
if [ -f "$PARALLEL_FAIL_FLAG" ]; then
    echo -e "\n\e[31m--- PARALLEL TEST GENERATION FAILED ---\e[0m"
    echo "One or more parallel jobs failed:"
    cat "$PARALLEL_FAIL_FLAG"
    rm -f "$PARALLEL_FAIL_FLAG" # Clean up the flag file
    echo "Continuing despite failures (tables will include missing data)"
fi

# Capture human-readable time and Unix timestamp for end
end_wall_time=$(date +"%Y-%m-%d %H:%M:%S")
end_ts=$(date +%s)
echo "Sikraken $script_name: Start Wall Time: $start_wall_time"
echo "Sikraken $script_name: End Wall Time: $end_wall_time"
duration_seconds=$((end_ts - start_ts))
duration_hms=$(date -u -d @"$duration_seconds" +"%H:%M:%S")
echo "Sikraken $script_name: Duration: $duration_hms"
echo "Duration: $duration_hms" >> $log_file

generate_table_script="$SIKRAKEN_INSTALL_DIR/SikrakenDevSpace/bin/helper/create_category_test_run_table.sh $output_dir"
echo "Sikraken $script_name: now calling $generate_table_script"
$generate_table_script

# update the overall category summary table for all the previous runs
generate_summary="$SIKRAKEN_INSTALL_DIR/SikrakenDevSpace/bin/helper/view_category_compare.sh ./SikrakenDevSpace/categories/$category/"
echo "Sikraken $script_name log: now calling $generate_summary"
$generate_summary

echo "Sikraken $script_name log: has ended."
aplay SikrakenDevSpace/call_to_arms.wav &> /dev/null &
