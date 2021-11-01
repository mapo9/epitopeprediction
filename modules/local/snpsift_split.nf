// Import generic module functions
include { initOptions; saveFiles; getSoftwareName; getProcessName } from './functions'

params.options = [:]
options        = initOptions(params.options)

process SNPSIFT_SPLIT {

    publishDir "${params.outdir}",
        mode: params.publish_dir_mode,
        saveAs: { filename -> saveFiles(filename:filename, options:params.options, publish_dir:'', meta:[:], publish_by_meta:[]) }

    conda (params.enable_conda ? "conda-forge::snpsift:4.2" : null)
    if (workflow.containerEngine == 'singularity' && !params.singularity_pull_docker_container) {
        container "https://depot.galaxyproject.org/singularity/snpsift:4.2--hdfd78af_5"
    } else {
        container "quay.io/biocontainers/snpsift:4.2--hdfd78af_5"
    }

    input:
        tuple val(meta)

    output:
        tuple val(meta), path("*.vcf"), path("*.tsv"), path("*.GSvar"), emit: splitted
        path "versions.yml", emit: versions
    // when: !params.peptides && !params.show_supported_models // TODO: Remove this by creating a nstatement in the main workflow

    script:
    // TODO: put the if else statement outside of the process call
    // if ( variants.toString().endsWith('.vcf') || variants.toString().endsWith('.vcf.gz') ) {
        // """
        // SnpSift split ${variants}
        // """
    // }
    // else {
        // """
        // sed -i.bak '/^##/d' ${variants}
        // csvtk split ${variants} -t -C '&' -f '#chr'
        // """
    // }
    """
        SnpSift split ${meta.variants}
        cat <<-END_VERSIONS > versions.yml
            ${getProcessName(task.process)}:
                snpsift: \$(echo \$(SnpSift 2>&1) )
            END_VERSIONS
    """
}
