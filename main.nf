#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/epitopeprediction
========================================================================================
 nf-core/epitopeprediction Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/epitopeprediction
 #### Authors
 Christopher Mohr christopher-mohr <christopher.mohr@qbic.uni-tuebingen.de> - https://github.com/christopher-mohr>
 Alexander Peltzer apeltzer <alexander.peltzer@qbic.uni-tuebingen.de> - https://github.com/apeltzer
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/epitopeprediction --somatic_mutations '*.vcf.gz' --alleles '*.alleles' -profile standard,docker

    Mandatory arguments:
      --somatic_mutations           Path to input data (must be surrounded with quotes)
      --alleles                     Path to the file containing the MHC alleles
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more

    Alternative inputs:
      --peptides                    Path to TSV file containing peptide sequences (minimum required: id and sequence column)
    
    Pipeline options:
      --filter_self                 Specifies that peptides should be filtered against the specified human proteome references Default: false
      --wild_type                   Specifies that wild-type sequences of mutated peptides should be predicted as well Default: false
      --mhc_class                   Specifies whether the predictions should be done for MHC class I or class II. Default: 1
      --peptide_length              Specifies the maximum peptide length Default: MHC class I: 8 to 11 AA, MHC class II: 15 to 16 AA 
      --tools                       Specifies a list of tool(s) to use. Available are: 'syfpeithi', 'mhcflurry', 'mhcnuggets-class-1', 'mhcnuggets-class-2'. Can be combined in a list separated by comma.

    References                      If not specified in the configuration file or you wish to overwrite any of the references
      --reference_genome            Specifies the ensembl reference genome version (GRCh37, GRCh38) Default: GRCh37
      --reference_proteome          Specifies the reference proteome(s) used for self-filtering

    Additional inputs:
      --protein_quantification      Path to protein quantification file (MaxQuant) for additional annotation
      --gene_expression             Path to gene expression file for additional annotation
      --differential_gene_expression  Path to differential gene expression file for additional annotation
      --ligandomics_identification  Path to ligandomics identification file for additional annotation
       
    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

// Documentation and Reporting Output
multiqc_config = file(params.multiqc_config)
output_docs = file("$baseDir/docs/output.md")

// List of coding genes for Ensembl ID to HGNC mapping
gene_list = file(params.gene_list)

//Generate empty channels for peptides and variants
ch_split_peptides = Channel.empty()
ch_split_variants = Channel.empty()



if ( params.peptides ) {
    if ( params.wild_type ) {
        exit 1, "Peptide input not compatible with wild-type sequence generation."
    }
    Channel
        .fromPath(params.peptides)
        .ifEmpty { exit 1, "Peptide input not found: ${params.peptides}" }
        .set { ch_split_peptides }
}
else if (params.somatic_mutations) {
    Channel
        .fromPath(params.somatic_mutations)
        .ifEmpty { exit 1, "Variant file not found: ${params.somatic_mutations}" }
        .set { ch_split_variants }
}
else {
    exit 1, "Please specify a file that contains annotated variants OR a file that contains peptide sequences."
}

if ( !params.alleles ) {
    exit 1, "Please specify a file containing MHC alleles."
}
else {
    allele_file = file(params.alleles)
}

if ( params.mhc_class != 1 && params.mhc_class != 2 ){
    exit 1, "Invalid MHC class option: ${params.mhc_class}. Valid options: 1, 2"
}

if ( (params.mhc_class == 1 && params.tools.contains("mhcnuggets-class-2")) || (params.mhc_class == 2 && params.tools.contains("mhcnuggets-class-1")) ){
    log.warn "Provided MHC class is not compatible with the selected MHCnuggets tool. Output might be empty.\n"
}

if ( params.filter_self & !params.reference_proteome ){
    params.reference_proteome = file("$baseDir/assets/")
}

//
// NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// If you want to use the channel below in a process, define the following:
//   input:
//   file fasta from ch_fasta
//

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Header log info
log.info nfcoreHeader()
def summary = [:]
summary['Pipeline Name']  = 'nf-core/epitopeprediction'
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
//Pipeline Parameters
if ( params.alleles ) summary['Alleles'] = params.alleles
if ( params.gene_expression ) summary['Gene Expression'] = params.gene_expression
summary['Gene List'] = params.gene_list
if ( params.ligandomics_identification ) summary['Ligandomics Identification'] = params.ligandomics_identification
summary['Max. Peptide Length'] = params.peptide_length
summary['MHC Class'] = params.mhc_class
if ( params.peptides ) summary['Peptides'] = params.peptides
if ( params.protein_quantification ) summary['Protein Quantification'] = params.protein_quantification
summary['Reference Genome'] = params.reference_genome
if ( params.reference_proteome ) summary['Reference proteome'] = params.reference_proteome
summary['Self-Filter'] = params.filter_self
summary['Tools'] = params.tools
if ( params.somatic_mutations ) summary['Variants'] = params.somatic_mutations
summary['Wild-types'] = params.wild_type
//Standard Params for nf-core pipelines
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile == 'awsbatch') {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"


// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-epitopeprediction-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/epitopeprediction Workflow Summary'
    section_href: 'https://github.com/nf-core/epitopeprediction'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    multiqc --version > v_multiqc.txt
    csvtk version > v_csvtk.txt
    echo \$(SnpSift 2>&1) > v_snpsift.txt
    echo \$(mhcflurry-predict --version 2>&1) > v_mhcflurry.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * STEP 1 - Split variant data
 */
process splitVariants {
    input:
    file variants from ch_split_variants

    when: !params.peptides

    output:
    file '*chr*.vcf' optional true into ch_splitted_vcfs
    file '*chr*.tsv' optional true into ch_splitted_tsvs
    file '*chr*.GSvar' optional true into ch_splitted_gsvars

    script:
    if ( variants.toString().endsWith('.vcf') || variants.toString().endsWith('.vcf.gz') ) {
        """
        SnpSift split ${variants}
        """
    }
    else {
        """
        sed -i.bak '/^##/d' ${variants}
        csvtk split ${variants} -t -C '&' -f '#chr'
        """
    }
}

/*
 * STEP 1 - Split peptide data
 */
process splitPeptides {
    input:
    file peptides from ch_split_peptides

    when: !params.somatic_mutations

    output:
    file '*.tsv' into ch_splitted_peptides

    // @TODO
    // splitting mechanism missing
    script:
    """
    cat ${peptides} > "${peptides.fileName}.tsv"
    """
}


/*
 * STEP 2 - Run epitope prediction
 */
process peptidePrediction {
    
   input:
   file inputs from ch_splitted_vcfs.flatten().mix(ch_splitted_tsvs.flatten(), ch_splitted_gsvars.flatten(), ch_splitted_peptides.flatten())
   file alleles from file(params.alleles)

   output:
   file "*.tsv" into ch_predicted_peptides
   file "*.json" into ch_json_reports
   
   script:
   def input_type = params.peptides ? "--peptides ${inputs}" : "--somatic_mutations ${inputs}"
   def ref_prot = params.reference_proteome ? "--reference_proteome ${params.reference_proteome}" : ""
   def wt = params.wild_type ? "--wild_type" : ""
   def qt = params.protein_quantification ? "--protein_quantification ${params.protein_quantification}" : ""
   def ge = params.gene_expression ? "--gene_expression ${params.gene_expression}" : ""
   def de = params.differential_gene_expression ? "--differential_gene_expression ${params.differential_gene_expression}" : ""
   def li = params.ligandomics_identification ? "--ligandomics_identification ${params.ligandomics_identification}" : ""
   """
   epaa.py ${input_type} --identifier ${inputs.baseName} --alleles $alleles --mhcclass ${params.mhc_class} --length ${params.peptide_length} --tools ${params.tools} --reference ${params.reference_genome} --gene_reference ${gene_list} ${ref_prot} ${qt} ${ge} ${de} ${li} ${wt}
   """
}

/*
 * STEP 3 - Combine epitope prediction results
 */
process mergeResults {
    publishDir "${params.outdir}/results", mode: 'copy'

    input:
    file predictions from ch_predicted_peptides.collect()

    output:
    file 'prediction_result.tsv'

    script:
    def single = predictions instanceof Path ? 1 : predictions.size()
    def merge = (single == 1) ? 'cat' : 'csvtk concat -t'

    """
    $merge $predictions > prediction_result.tsv
    """
}

/*
 * STEP 4 - Combine epitope prediction reports
 */

process mergeReports {
    publishDir "${params.outdir}/results", mode: 'copy'

    input:
    file jsons from ch_json_reports.collect()

    output:
    file 'prediction_report.json'

    script:
    def single = jsons instanceof Path ? 1 : jsons.size()
    def command = (single == 1) ? "cat ${jsons} > prediction_report.json" : "merge_jsons.py --input \$PWD"

    """
    $command
    """
}

/*
 * STEP 5 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config
    file ('software_versions/*') from ch_software_versions_yaml
    file workflow_summary from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config .
    """
}

/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/epitopeprediction] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/epitopeprediction] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/epitopeprediction] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/epitopeprediction] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/epitopeprediction] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nf-core/epitopeprediction] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
        log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}"
        log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}"
    }

    if (workflow.success) {
        log.info "${c_purple}[nf-core/epitopeprediction]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/epitopeprediction]${c_red} Pipeline completed with errors${c_reset}"
    }

}

def nfcoreHeader() {
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/epitopeprediction v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
