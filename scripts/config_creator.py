#!/usr/bin/env python3

import argparse
from collections import defaultdict
import glob
import json
import jsonschema
import os
import pandas as pd
import re
import sys
import yaml


#https://stackoverflow.com/a/5369814
class Tree(defaultdict):
    def __init__(self, value=None):
        super(Tree, self).__init__(Tree)
        self.value = value

class _InputValidationError(Exception):
    """Raised for problematic input data."""

    def __init__(self, msg, *args):
        super(_InputValidationError, self).__init__(msg, *args)


def parse_per_lib(args):
    """
    Takes a pandas df as input, and returns a dict of dicts reflecting the per-library data
    """
    sample_table = pd.read_csv(args.per_lib_input, dtype=str)
    validate_sample_table(sample_table, args.homer_only)

    per_lib_dict = dict()

    if not args.homer_only:
        lib_basepaths = sample_table[['sample', 'basepath']].values

        per_lib_dict['sample_paths'] = assign_libpaths(args, lib_basepaths)

        othercols = sample_table.columns.drop(['lib', 'basepath', 'sample'])
    else:
        othercols = sample_table.columns.drop(['lib', 'sample']) # For homer_only, basepath isn't present, so can't drop it

    for c in othercols:
        two_cols = ['sample', c]
        combined_name = "_".join(two_cols)
        col_dict = dict(sample_table[two_cols].dropna().values)
        per_lib_dict[combined_name] = col_dict

    return(per_lib_dict)


def assign_libpaths(args, lib_basepaths):
    """
    Takes an array of arrays as input, each inner array having two items,
    library name and basepath. Calls basepath_to_filepathsdict for each library
    and adds each libraries' filepathsdict to the libpaths dict
    """
    libpaths_dict = dict()
    for row in lib_basepaths:
        sample, path = row
        libpaths_dict[sample] = basepath_to_filepathsdict(path, args.file_glob, args.capture_regex)
    return(libpaths_dict)


def basepath_to_filepathsdict(basepath, glob_regex, capture_regex):
    """
    Takes a basepath, and two regex strings, uses glob to find corresponding fastq files
    Then subclassifies these files by lane (readgroup) and read orientation
    and places these into a dict
    """
    all_fastqs = glob.glob(os.path.join(basepath, glob_regex))

    if len(all_fastqs) == 0:
        raise RuntimeError("Input files not found in the directory " + basepath + "\nNote that inputs are found using the following shell glob: " + glob_regex)

    readgroups = defaultdict(list)
    # If no_capture was specified on the commandline, capture_regex will be False
    if capture_regex == False:
        readgroups[1] = all_fastqs
    else:
        for fq in all_fastqs:
            basename = os.path.basename(fq)
            rmatch = re.match(capture_regex, basename)
            if not rmatch:
                msg_fmt = ("\nFile {} did not match regular expression {}. "
                    "Could not capture desired group(s).\n"
                    "Note that all input files should be formatted consistently. "
                    "File glob and capture regex can be controlled with --file_glob and --capture_regex if desired.")
                raise RuntimeError(msg_fmt.format(basename, capture_regex))
            if rmatch.group(0) == basename:
                readnum = rmatch.group(1)
                #Add fastq to dict
                readgroups[readnum].append(fq)
        for key in readgroups:
            readgroups[key].sort()
    return(readgroups)

def read_input(input_filename):
    """Takes input filename as argument, chooses to load json or yaml based on file extension,
    and handles any errors that occur as the input file is loaded. Returns the loaded config dictionary.
    """
    if input_filename.endswith('.yaml') or input_filename.endswith('.yml'):
        try:
            with open(input_filename) as infile:
                config_dict = yaml.load(infile, Loader=yaml.SafeLoader)
        except (yaml.parser.ParserError, yaml.scanner.ScannerError) as e:
            print(e)
            msg = "Error: Error loading YAML. Assuming YAML input based on file extension."
            sys.exit(str(msg))

    elif input_filename.endswith('.json'):
        try:
            with open(input_filename) as infile:
                config_dict = json.load(infile)
        except json.decoder.JSONDecodeError as e:
            print(e)
            msg = "Error: Error loading JSON. Assuming JSON input based on file extension."
            sys.exit(str(msg))

    else:
        msg = "Error: Cannot assume YAML or JSON based on file extension. Filename is {}.".format(input_filename)
        sys.exit(str(msg))

    return config_dict

def validate_config_with_schema(config_dict, schema_filename):
    """Takes config dictionary and schema filename as arguments. Loads the schema file (assumes YAML format),
    and uses jsonschema.validate to compare the config dictionary to the schema. Handles any
    errors thrown by the validator.
    """
    try:
        with open(schema_filename) as infile:
            schema_dict = yaml.load(infile, Loader=yaml.SafeLoader)
    except:
        msg = "Error loading schema file {}. Expecting YAML.".format(schema_filename)

    try:
        jsonschema.validate(config_dict, schema_dict)
    except Exception as e:
        #print(e)
        msg = "Error validating config against schema:\nSchema file: {}\nReason: {}".format(schema_filename, e.message)
        sys.exit(str(msg))

def validate_sample_table(sample_table, homer_only):
    """Takes pandas dataframe as input (loaded from per_lib_input), verifies that required colums are present,
    and that samplenames don't contain invalid characters. Only alphanumeric and _ are allowed.
    """
    if not homer_only:
        required_cols = set(['lib', 'sample', 'basepath'])
    else:
        required_cols = set(['sample'])
    actual_cols = set(sample_table.columns)
    missing_cols = required_cols - actual_cols
    if missing_cols:
        raise RuntimeError("Missing required {} column(s)".format(missing_cols))
    # Error checking for samplenames - can only contain alphanumeric and _
    samplenames = sample_table['sample'].to_list()
    goodname_matches = [re.match(r'^[a-zA-Z0-9_]+$', x) for x in samplenames]
    problematic_samples = []
    for i, name in enumerate(goodname_matches):
        if name == None:
            problematic_samples.append(samplenames[i])
    if problematic_samples:
        raise RuntimeError("Samplenames contain invalid characters: {}".format(problematic_samples))


if __name__ == '__main__':

    parser = argparse.ArgumentParser(prog='python config_creator.py', description = "")
    parser.add_argument('-g', '--general_input', required=True, help="json or yaml file with general config information (results location, reference paths, etc)")
    parser.add_argument('-p', '--per_lib_input', required=True, help="CSV file with per-lib information")
    parser.add_argument('-r', '--results_dir', required=True, help="Results basepath to use in the config")
    parser.add_argument('-t', '--temp_dir', required=True, help="Temporary directory basepath to use in the config")
    parser.add_argument('--file_glob', help="Override default file glob of '*.fastq.gz'", default='*.fastq.gz')
    parser.add_argument('--capture_regex', help="Override default regular expression which determines read number by filename. Default is '.*_R([12])(?=[_\.]).*\.fastq\.gz'", default='.*_R([12])(?=[_\.]).*\.fastq\.gz')
    parser.add_argument('--no_capture', dest = 'capture_regex', action='store_false', help="Treat all input fastqs as read1, do not attempt to capture read number from filename.")
    parser.add_argument('--homer_only', action='store_true', help="Create a config for running only the Homer portion of the pipeline. Default is False.", default=False)

    args = parser.parse_args()

    config_dict = read_input(args.general_input)

    config_dict.update({'results_dir' : args.results_dir, 'tmpdir' : args.temp_dir})

    # Section to add results, logs, temp dir (logs is within results)
    logs_dir = os.path.join(args.results_dir, 'logs')
    os.makedirs(logs_dir, exist_ok=True)
    os.makedirs(args.temp_dir, exist_ok=True)

    per_lib = parse_per_lib(args)

    config_dict.update(per_lib)

    config_dict = json.loads(json.dumps(config_dict)) #Standardize dict type throughout object by using json as intermediate

    if args.homer_only: # Remove unnecessary keys from the config_dict in the homer_only case
        [config_dict.pop(x, None) for x in ['samtools_prune_flags','deeptools_bamcoverage_params','bwa_index']]

    pipeline_basedir = os.path.realpath(os.path.dirname(os.path.dirname(__file__)))
    if not args.homer_only:
        schema_filename = os.path.join(pipeline_basedir, 'tests', 'full_config_schema.yaml')
    else:
        schema_filename = os.path.join(pipeline_basedir, 'tests', 'homer_config_schema.yaml')

    validate_config_with_schema(config_dict, schema_filename)

    yaml.dump(config_dict, sys.stdout, default_flow_style=False)
