import os
import re
import json
import argparse
from pathlib import Path

s3_url = 'https://testcov-results-bucket.s3.eu-west-1.amazonaws.com'

def replace_local_paths_with_s3(html_content, run_folder):
    run_folder = run_folder.rstrip("/")  #Removing forward slash at end of folder name 

    pattern = r'href="(?!https?://)([^"]+)"' #Regex for detecting href and doesn't already contain https

    def repl(match): #Matches by the pattern are used as a parameter in this function once they're found
        path = match.group(1) #Using first match 

        if path.startswith("file://"):
            path = path.replace("file://", "", 1) #ELiminating the file path

        path = os.path.normpath(path) #Eliminate double slashes in path if any
        p = Path(path) #Turns into Path object that has methods to perform operations on it 
        filename = p.name #Getting file name
        problem_folder = p.parent.name #Getting parent folder name to match object format in S3

        relative_path = f"{run_folder}/{problem_folder}/{filename}" #Combining the name e.g 2025_11_17_19_00/Problem03_label00/Problem03_label00.i
        return f'href="{s3_url}/{relative_path}"' #Adding to S3 url

    return re.sub(pattern, repl, html_content) #Scans for the pattern in html_content and then calls repl to process the filepath with each pattern found

def process_html_file(input_dir, run_folder):
    input_dir_path = Path(input_dir)
    html_file_name = 'category_test_run_results.html'
    html_full_path = os.path.join(input_dir_path, html_file_name)

    html_files = list(input_dir_path.glob(html_file_name)) #Get all files with the name category_test_run_results.html in the input directory to count the number of files processed
    report_data = [] 

    try:
        with open(html_full_path, 'r') as file: #Read file 
            html_content = file.read()
        converted_html = replace_local_paths_with_s3(html_content, run_folder) #Read html contents and replace file paths with S3 in order to link to objects in bucket
        report_data.append({ #Appending updated data to the html 
            "file": str(html_full_path),
            "content": converted_html
        })

    except Exception as e:
        return {"body": f"Error reading file {html_full_path}: {str(e)}"}

    with open(html_full_path, 'w') as f:
        f.write(converted_html)

    return {"body": f"Processed {len(html_files)} HTML files.", "data": report_data}

def main():
    parser = argparse.ArgumentParser(description="Generate a report from test logs.") #Getting Arguments
    parser.add_argument('input_dir', type=str, help="Path to the input directory") #Requiring input directory (ECA Category Folder)
    parser.add_argument('--run_folder', type=str, required=True, help="Run folder name to use in S3 URLs") #Sets the folder name that will be used in the S3 bucket

    args = parser.parse_args()
    result = process_html_file(args.input_dir, args.run_folder)

    print(result['body'])
    if 'data' in result:
        print(json.dumps(result['data'], indent=4))

if __name__ == "__main__":
    main()
