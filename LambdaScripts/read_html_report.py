import json
import boto3

# Initialize S3 client
s3 = boto3.client('s3')

def lambda_handler(event, context):
    bucket_name = 'testcov-results-bucket'
    object_key = 'category_test_run_results.html'  # File to search for

    # List objects with the delimiter '/' to only show directories
    response = s3.list_objects_v2(
        Bucket=bucket_name,
        Delimiter='/'
    )

    # CommonPrefixes is a list of dictionaries of prefixes which are the names given to the S3 objects/files in the S3  directory, if it's empty, it means there's no files
    if 'CommonPrefixes' not in response:
        return {
            'statusCode': 404,
            'body': json.dumps('No folders found in the bucket.')
        }

    # The list of directory names is the value to the key "prefix" stored in the list of dictonaries in CommonPrefixes which will be used to find the most recently created folder
    folders = [prefix['Prefix'] for prefix in response['CommonPrefixes']] 

    print("Folders: ",folders)

    most_recent_folder = None
    most_recent_time = None

    # Iterate through each folder to find the most recent file which should be the .html file
    for folder in folders:
        # List objects within the folder to find the most recent file 
        folder_response = s3.list_objects_v2( 
            Bucket=bucket_name,
            Prefix=folder
        )
        
        if 'Contents' in folder_response:
            # Get the most recent object in this folder, max gets the folder with the highest value/Last Modified Date and passes the value of contents to the lambda 
            recent_object = max(folder_response['Contents'], key=lambda x: x['LastModified']) #The anonymous lambda function finds the most recent folder by comparing the last modified files passed from Contents 
            folder_last_modified = recent_object['LastModified']
            print("FOLDER RESPONSE CONTENTS:", folder_response['Contents']) #Print line used when debugging
            # Compare with the most recent folder we've seen
            if most_recent_time is None or folder_last_modified > most_recent_time:
                most_recent_folder = folder
                most_recent_time = folder_last_modified

    if not most_recent_folder: #Returning an error if there's nothing in the folders
        return {
            'statusCode': 404,
            'body': json.dumps('No folder found with objects in it.')
        }

    #Listing the contents of the most recent folder found to find the HTML file
    folder_contents_response = s3.list_objects_v2(
        Bucket=bucket_name,
        Prefix=most_recent_folder
    )

    #Check if 'Contents' is present in the folder's response
    if 'Contents' not in folder_contents_response:
        return {
            'statusCode': 404,
            'body': json.dumps(f'No contents found in folder {most_recent_folder}.')
        }

    # Checking for object with the name of report generated 
    html_report = [obj for obj in folder_contents_response['Contents'] if obj['Key'].endswith(object_key)]

    if html_report:
        file_obj = html_report[0] #Getting first S3 object found that has the correct key name as a list is returned
        # Generate a pre-signed URL for the specific HTML file (optional)
        url = s3.generate_presigned_url(
            'get_object',
            Params={'Bucket': bucket_name, 'Key': file_obj['Key']}, #Getting key/name of that object returned
            ExpiresIn=3600  # URL valid for 1 hour, presigned URLs have expiration, will find a way around this in the future
        )

        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': f"Found the HTML file: {file_obj['Key']}",
                'url': url  #.html file url from S3 bucket that can be viewed by anyone with the link
            })
        }
    else:
        return {
            'statusCode': 404, # Error message in the case that 
            'body': json.dumps(f'{object_key} not found in folder {most_recent_folder}.')
        }
