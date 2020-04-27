import os
import sys
import functools


# GENERIC DATA

INCLUDE_CHRS = {
    'hg19': ['chr{}'.format(i) for i in range(1, 23)] + ["chrX", "chrY"],
    'hg38': ['chr{}'.format(i) for i in range(1, 23)] + ["chrX", "chrY"],
    'mm9': ['chr{}'.format(i) for i in range(1, 20)] + ["chrX", "chrY"],
    'mm10': ['chr{}'.format(i) for i in range(1, 20)] + ["chrX", "chrY"],
    'rn4': ['chr{}'.format(i) for i in range(1, 21)] + ["chrX", "chrY"],
    'rn5': ['chr{}'.format(i) for i in range(1, 21)] + ["chrX", "chrY"]
}


# Helper functions

def get_genome(library):
    return(config['lib_genome'][library])


# RESULT PATHS

prefix_results = functools.partial(os.path.join, config['results_dir'])
ALIGN_DIR = prefix_results('aligned')
PRUNE_DIR = prefix_results('pruned')
DISP_DIR = prefix_results('display_tracks')
HOMERTAG_DIR = prefix_results('tag')
HOMERPEAK_DIR = prefix_results('peaks')
HOMERMOTIF_DIR = prefix_results('homer_motifs')


# Load modules and setup software

#Setup for non-module software
try:
    igvtools_loc = config['non_module_software']['igvtools']
    wigToBigWig_loc = config['non_module_software']['wigToBigWig']
except:
    logger.info("Cannot find software locations in config. Defaulting to rjhryan_turbo locations")

    igvtools_loc = "/nfs/turbo/path-rjhryan-turbo/software/igvtools/v2_3_98/igvtools.jar"
    wigToBigWig_loc = "/nfs/turbo/path-rjhryan-turbo/software/ucsc/wigToBigWig"


#The loaded software versions are explicitly stated here.
#If additional functions are added above without explicit versions in the string, add inline comments to indicate
software_strings = [
    "function igvtools() {{ java -jar " + igvtools_loc + " $@ ; }} ;",
    "function wigToBigWig() {{ " + wigToBigWig_loc + " $@ ; }} ;", #Version: wigToBigWig v 4
    "module load Bioinformatics ;"
    "module load picard-tools/2.8.1 ;",
    "module load bwa/0.7.15 ;",
    "module load samtools/1.5 ;",
    "module load bedtools2/2.25.0 ;",
    "module load homer/4.8 ;",
    "module load python3.7-anaconda/2019.07 ;" #Provides access to deeptools bamCoverage - deeptools library may need upgrading depending on passed arguments. Tested using deeptools 3.2.1
]
shell.prefix("".join(software_strings))

SCRIPTS_DIR = os.path.join(os.getcwd(), 'scripts')


# Set workdir - If running on cluster, logs will be placed in this location
workdir:
    config['flux_log_dir']


# Rules

rule all:
    input:
        expand(os.path.join(DISP_DIR, "{library}.tdf"), library=config['lib_paths'].keys()), #Create tdfs for all samples
        expand(os.path.join(DISP_DIR, "{library}.1m.bw"), library=config['lib_paths'].keys()), #Create bigwigs for all samples
        expand(os.path.join(HOMERPEAK_DIR, "{library}_BLfiltered.hpeaks"), library=config['lib_input'].keys()), #Call peaks for all samples with matched inputs
        expand(os.path.join(HOMERMOTIF_DIR, "{library}"), library=config['lib_homer_fmg_genome'].keys()), #Homermotifs for all samples with a specified genome for homer findMotifsGenome


include:
    "Snakefile_alignment_bwa_aln_pe"

rule mark_duplicates:
    input:
        os.path.join(ALIGN_DIR, "{library}.merged.bam")
    output:
        bam = os.path.join(ALIGN_DIR, "{library}.mrkdup.bam"),
        metric = os.path.join(ALIGN_DIR, "{library}.mrkdup.metric")
    params:
        tmpdir = config['tmpdir']
    shell:
        "export JAVA_OPTIONS=-Xmx12g ; "
        "PicardCommandLine MarkDuplicates I={input} O={output.bam} "
        "METRICS_FILE={output.metric} "
        "ASSUME_SORTED=True "
        "VALIDATION_STRINGENCY=LENIENT "
        "TMP_DIR={params.tmpdir}"

rule index_dupmarked_bams:
    input:
        os.path.join(ALIGN_DIR, "{library}.mrkdup.bam")
    output:
        os.path.join(ALIGN_DIR, "{library}.mrkdup.bai")
    shell:
        "samtools index {input} {output}"

rule samtools_prune:
    input:
        bam = os.path.join(ALIGN_DIR, "{library}.mrkdup.bam"),
        bai = os.path.join(ALIGN_DIR, "{library}.mrkdup.bai")
    output:
        bam = temp(os.path.join(PRUNE_DIR, "{library}.stpruned.bam"))
    params:
        incl_chr = lambda wildcards: INCLUDE_CHRS[get_genome(wildcards.library)],
        flags = config['samtools_prune_flags']
    shell:
        "samtools view -b {params.flags} {input.bam} {params.incl_chr} > {output.bam}"

rule namesort_st_pruned:
    input:
        os.path.join(PRUNE_DIR, "{library}.stpruned.bam")
    output:
        temp(os.path.join(PRUNE_DIR, "{library}.ns.bam"))
    shell:
        "samtools sort -n -o {output} {input}"

rule X0_pair_filter:
    input:
        os.path.join(PRUNE_DIR, "{library}.ns.bam")
    output:
        temp(os.path.join(PRUNE_DIR, "{library}.x0_filtered.bam"))
    params:
        config['X0_pair_filter_params']
    shell:
        "python {SCRIPTS_DIR}/X0_pair_filter.py {params} -b {input} -o {output}"

rule coordsort_index_final_pruned:
    input:
        os.path.join(PRUNE_DIR, "{library}.x0_filtered.bam")
    output:
        bam = os.path.join(PRUNE_DIR, "{library}.pruned.bam"),
        bai = os.path.join(PRUNE_DIR, "{library}.pruned.bai")
    shell:
        "samtools sort -o {output.bam} {input} ;"
        "samtools index {output.bam} {output.bai}"

rule igvtools_count_tdf:
    input:
        os.path.join(PRUNE_DIR, "{library}.pruned.bam")
    output:
        os.path.join(DISP_DIR, "{library}.tdf")
    params:
        genome = lambda wildcards: get_genome(wildcards.library),
        args = config['igvtools_count_params']
    shell:
        "igvtools count {params.args} {input} {output} {params.genome}"

rule deeptools_bamcoverage_bw:
    input:
        bam = os.path.join(PRUNE_DIR, "{library}.pruned.bam"),
        bai = os.path.join(PRUNE_DIR, "{library}.pruned.bai")
    output:
        os.path.join(DISP_DIR, "{library}.1m.bw")
    params:
        blacklist = lambda wildcards: config['blacklist'][get_genome(wildcards.library)],
        args = config['deeptools_bamcoverage_params']
    shell:
        "bamCoverage --bam {input.bam} -o {output} -bl {params.blacklist} {params.args}"

rule makeTagDirectory:
    input:
        os.path.join(PRUNE_DIR, "{library}.pruned.bam")
    output:
        directory(os.path.join(HOMERTAG_DIR, "{library}"))
    params:
        genome = lambda wildcards: get_genome(wildcards.library),
        params = config['makeTagDir_params']
    shell:
        "makeTagDirectory {output} {params.params} -genome {params.genome} {input}"

rule findPeaks:
    input:
        sample = os.path.join(HOMERTAG_DIR, "{library}"),
        input = lambda wildcards: os.path.join(HOMERTAG_DIR, config['lib_input'][wildcards.library])
    output:
        os.path.join(HOMERPEAK_DIR, "{library}.all.hpeaks")
    params:
        config['homer_findPeaks_params']
    shell:
        "findPeaks {input.sample} -i {input.input} {params} -o {output}"

rule pos2bed:
    input:
        os.path.join(HOMERPEAK_DIR, "{library}.all.hpeaks")
    output:
        os.path.join(HOMERPEAK_DIR, "{library}.all.bed")
    shell:
        "pos2bed.pl {input} > {output}"

rule blacklist_filter_bed:
    input:
        os.path.join(HOMERPEAK_DIR, "{library}.all.bed"),
    output:
        os.path.join(HOMERPEAK_DIR, "{library}_BLfiltered.bed"),
    params:
        blacklist = lambda wildcards: config['blacklist'][get_genome(wildcards.library)]
    shell:
        "bedtools intersect -a {input} -b {params.blacklist} -v > {output}"

rule keepBedEntriesInHpeaks:
    input:
        filtbed = os.path.join(HOMERPEAK_DIR, "{library}_BLfiltered.bed"),
        allhpeaks = os.path.join(HOMERPEAK_DIR, "{library}.all.hpeaks")
    output:
        os.path.join(HOMERPEAK_DIR, "{library}_BLfiltered.hpeaks")
    shell:
        "python {SCRIPTS_DIR}/keepBedEntriesInHpeaks.py -i {input.allhpeaks} -b {input.filtbed} -o {output}"

rule findMotifsGenome:
    input:
        os.path.join(HOMERPEAK_DIR, "{library}_BLfiltered.hpeaks")
    output:
        directory(os.path.join(HOMERMOTIF_DIR, "{library}"))
    params:
        genome = lambda wildcards: config['lib_homer_fmg_genome'][wildcards.library],
        params = config['homer_fmg_params']
    shell:
        "findMotifsGenome.pl {input} {params.genome} {output} {params.params}"