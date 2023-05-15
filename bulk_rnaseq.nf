nextflow.enable.dsl=2

process fastqc {
    //debug true
    tag "${meta.sample_name}"
    cpus 8
    memory '4 GB'
    time "2h"

    publishDir "${projectDir}/analysis/fastqc/"

    module 'FastQC/0.11.9'

    input:
    tuple val(meta), path(reads)

    output:
    path ("*.zip"), emit: zips
    path ("*.html"), emit: htmls

    script:
    def threads = task.cpus - 1
    """
    fastqc --threads ${threads} ${reads}
    """
}

// process FASTP {
//     debug true
//     tag "${sample_name}"
//     // label "universal"
//     cpus 8
//     memory '8 GB'
//
//     publishDir "${projectDir}/analysis/fastp/"
//
//     module 'fastp/0.21.0'
//
//     input:
//     tuple val(sample_name), path(reads)
//
//     output:
//     tuple val(sample_name), path("${sample_name}_trimmed.R{1,2}.fq.gz"), emit: trim_reads
//     path("${sample_name}.fastp.json"), emit: json
//
//     script:
//     """
//     fastp \
//     -i ${reads[0]} \
//     -I ${reads[1]} \
//     --thread ${task.cpus} \
//     --detect_adapter_for_pe \
//     --qualified_quality_phred 25 \
//     -o ${sample_name}_trimmed.R1.fq.gz \
//     -O ${sample_name}_trimmed.R2.fq.gz \
//     --json ${sample_name}.fastp.json
//     """
// }

process trim_galore {
    //debug true
    tag "${meta.sample_name}"
    cpus 4
    memory '8 GB'
    time "2h"

    publishDir "${projectDir}/analysis/trim_galore/"

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta.sample_name), path("*.gz"), val(meta.single_end), emit: trim_reads
    path("*.html")
    path("*.zip")
    path("*.txt")

    script:
    def threads = task.cpus - 1
    if(!meta.single_end) {
    """
    trim_galore \
    --paired \
    ${reads} \
    --cores ${threads} \
    -q 20 \
    --fastqc \
    --output_dir ./
    """
    } else {
    """
    trim_galore \
    ${reads[0]} \
    --cores ${task.cpus} \
    -q 20 \
    --fastqc \
    --output_dir ./
    """
    }
}

process star {
    //debug true
    tag "${sample_name}"
    cpus 12
    memory '42 GB'
    time "3h"

    publishDir "${projectDir}/analysis/star/", mode : "copy"

    module "STAR/2.7.10a"
    module 'samtools/1.16.1'

    input:
    tuple val(sample_name), path(reads), val(is_SE)

    output:
    tuple val(sample_name), path("${sample_name}.Aligned.sortedByCoord.out.bam"), val(is_SE), emit: bam
    tuple val(sample_name), path("${sample_name}.Aligned.sortedByCoord.out.bam.bai"), emit: bai
    tuple val(sample_name), path("${sample_name}.Log.final.out"), emit: log_final
    tuple val(sample_name), path("${sample_name}.Log.out"), emit: log_out
    tuple val(sample_name), path("${sample_name}.ReadsPerGene.out.tab"), emit: read_per_gene_out
    tuple val(sample_name), path("${sample_name}.SJ.out.tab"), emit: sj_out
    tuple val(sample_name), path("${sample_name}._STAR*"), emit: out_dir // STARgenome and STARpass1

    script:
    index = params.star_index.(params.genome)
    def threads = task.cpus - 1
    """
    STAR \
    --runThreadN ${threads} \
    --genomeDir ${index} \
    --readFilesIn ${reads} \
    --twopassMode Basic \
    --readFilesCommand zcat \
    --outSAMtype BAM SortedByCoordinate \
    --outFileNamePrefix ${sample_name}. \
    --quantMode GeneCounts \
    --outStd Log 2> ${sample_name}.log \

    samtools index "${sample_name}.Aligned.sortedByCoord.out.bam"
    """
}

process qualimap {
    //debug true
    tag "${sample_name}"
    time "4h"

    cpus 8
    memory '16 GB'

    publishDir "${projectDir}/analysis/qualimap/"

    module 'qualimap/2.2.1'

    input:
    tuple val(sample_name), path(bam), val(is_SE)

    output:
    path("*"), emit: qualimap_out

    script:
    gtf = params.gtf.(params.genome)

    if ( ! is_SE ) {
        // if sample is paired end data
        """
        qualimap rnaseq -bam ${bam} \
        -gtf ${gtf} \
        --paired \
        -outdir quailmap_${sample_name} \
        --java-mem-size=6G \
        --sequencing-protocol strand-specific-reverse
        """
    } else {
        // if sample is single end data
        """
        qualimap rnaseq -bam ${bam} \
        -gtf ${gtf} \
        -outdir quailmap_${sample_name} \
        --java-mem-size=6G \
        --sequencing-protocol strand-specific-reverse
        """
    } // end if else
} // end process

process salmon {
    debug true
    tag "${sample_name}"
    time "3h"

    cpus 12
    memory '8 GB'

    module "salmon/1.9"
    publishDir "${projectDir}/analysis/salmon/"

    input:
    tuple val(sample_name), path(reads), val(is_SE)

    output:
    path("${sample_name}"), emit: salmon_out

    script:
    def threads = task.cpus - 1
    // this is adapted from https://github.com/ATpoint/rnaseq_preprocess/blob/99e3d9b556325d2619e6b28b9531bf97a1542d3d/modules/quant.nf#L29
    def is_paired = is_SE ? "single" : "paired"
    def add_gcBias = is_SE ? "" : "--gcBias "
    def use_reads = is_SE ? "-r ${reads}" : "-1 ${reads[0]} -2 ${reads[1]}"
    index = params.salmon_index.(params.genome)
    """
    salmon quant \
        -p $threads \
        -l A \
        -i ${index} \
        $use_reads \
        $add_gcBias \
        --validateMappings \
        -o ${sample_name}
    """
}

process seqtk {
    //debug true
    tag "${sample_name}"
    time "2h"

    cpus 2
    memory '4 GB'

    publishDir "${projectDir}/analysis/seqtk/"

    module 'seqtk/1.3'

    input:
    tuple val(sample_name), path(reads), val(is_SE)

    output:
    tuple val(sample_name), path("${sample_name}.subsample.100000.R1.fq.gz"), emit: subsample_reads

    script:
    """
    seqtk sample -s 100 ${reads[0]} 100000 | gzip -c > ${sample_name}.subsample.100000.R1.fq.gz
    """
}

 process sortMeRNA {
     //debug true
     tag "${sample_name}"
     time "2h"

     cpus 8
     memory '8 GB'

     publishDir "${projectDir}/analysis/sortMeRNA/"

     module 'sortmerna/4.3.6'

     input:
     tuple val(sample_name), path(reads)

     output:
     path ("*"), emit: sortMeRNA_out

     script:
     def threads = task.cpus - 1
     def idx = "/mnt/beegfs/kimj32/tools/sortmerna/idx"
     def rfam5_8s = "/home/kimj32/beegfs/tools/sortmerna/data/rRNA_databases/rfam-5.8s-database-id98.fasta"
     def rfam5s = "/home/kimj32/beegfs/tools/sortmerna/data/rRNA_databases/rfam-5s-database-id98.fasta"
     def silva_arc_16s = "/home/kimj32/beegfs/tools/sortmerna/data/rRNA_databases/silva-arc-16s-id95.fasta"
     def silva_arc_23s = "/home/kimj32/beegfs/tools/sortmerna/data/rRNA_databases/silva-arc-23s-id98.fasta"
     def silva_euk_18s = "/home/kimj32/beegfs/tools/sortmerna/data/rRNA_databases/silva-euk-18s-id95.fasta"
     def silva_euk_28s = "/home/kimj32/beegfs/tools/sortmerna/data/rRNA_databases/silva-euk-28s-id98.fasta"
     def silva_bac_16s = "/home/kimj32/beegfs/tools/sortmerna/data/rRNA_databases/silva-bac-16s-id90.fasta"
     def silva_bac_23s = "/home/kimj32/beegfs/tools/sortmerna/data/rRNA_databases/silva-bac-23s-id98.fasta"
     """
     sortmerna --threads ${threads} \
     -reads ${reads[0]} \
     --workdir sortMeRNA_${sample_name}  \
     --idx-dir ${idx}  \
     --ref ${rfam5s}  \
     --ref ${rfam5_8s}  \
     --ref ${silva_arc_16s}  \
     --ref ${silva_arc_23s}  \
     --ref ${silva_bac_16s}  \
     --ref ${silva_bac_23s}  \
     --ref ${silva_euk_18s}  \
     --ref ${silva_euk_28s}
     """
}

process fastq_screen {
    //debug true
    tag "${sample_name}"
    time "2h"

    cpus 4
    memory '8 GB'

    publishDir "${projectDir}/analysis/fastq_screen"

    module 'FastQScreen/0.14.1'
    module 'bowtie2/2.3.4.1'

    input:
    tuple val(sample_name), path(reads)

    output:
    path("*.html")
    path("*.txt")

    // threads option is already defined in fastq_screeN_conf
    script:
    def conf = params.fastq_screen_conf
    """
    fastq_screen --aligner bowtie2 \
    --conf ${conf} \
    ${reads[0]} \
    --outdir ./
    """
}

process multiqc {
    //debug true
    //tag "Multiqc on the project"
    time "1h"

    cpus 1
    memory '4 GB'

    publishDir "${projectDir}/analysis/multiqc/", mode : "copy"

    module 'python/3.6.2'

    input:
    path(files)

    output:
    path("*.html"), emit: multiqc_output

    script:
    """
    multiqc ${projectDir}/analysis --filename "multiqc_report.html" --ignore '*STARpass1'
    """
}

process tpm_calculator {
    //debug true
    tag "tpm_calculator on ${sample_name}"
    time "6h"

    cpus 8
    memory '16 GB'

    publishDir (
        path: "${projectDir}/analysis/tpm_calculator/",
        saveAs: {
            fn -> fn.replaceAll(".Aligned.sortedByCoord.out_genes", "")
        }
    )
    module "TPMCalculator/0.4.0"

    input:
    tuple val(sample_name), path(bam_file), val(is_SE)

    output:
    path("*out"), emit : "tpm_calculator_out"

    script:
    // -p option is for paired end data
    gtf = params.gtf.(params.genome)

    if ( ! is_SE ) {
    """
    TPMCalculator -g ${gtf} \
    -b ${bam_file} \
    -p
    """
    } else {
    """
    TPMCalculator -g ${gtf} \
    -b ${bam_file} \
    """
    }
}


log.info """
bulkRNAseq Nextflow
=============================================
samplesheet                           : ${params.samplesheet}
reference                       : ${params.ref_fa.(params.genome)}
"""

reference = Channel.fromPath(params.ref_fa.(params.genome), checkIfExists: true)

// See https://bioinformatics.stackexchange.com/questions/20227/how-does-one-account-for-both-single-end-and-paired-end-reads-as-input-in-a-next
ch_samplesheet = Channel.fromPath(params.samplesheet, checkIfExists: true)

// adapted from https://bioinformatics.stackexchange.com/questions/20227/how-does-one-account-for-both-single-end-and-paired-end-reads-as-input-in-a-next
ch_reads = ch_samplesheet.splitCsv(header:true).map {

    // This is the read1 and read2 entry
    r1 = it['fq1']
    r2 = it['fq2']

    // Detect wiether single-end or paired-end
    is_singleEnd = r2.toString() =='' ? true : false

    // The "meta" map, which is a Nextflow/Groovy map with id (the sample name) and a single_end logical entry
    meta = [sample_name: it['sample'], single_end: is_singleEnd]

    // We return a nested map, the first entry is the meta map, the second one is the read(s)
    r2.toString()=='' ? [meta, [r1]] : [meta, [r1, r2]]

}

workflow {

    fastqc(ch_reads)
    trim_galore(ch_reads)
    seqtk(trim_galore.out.trim_reads)
    fastq_screen(seqtk.out.subsample_reads)
    star(trim_galore.out.trim_reads)
    sortMeRNA(seqtk.out.subsample_reads)
    star.out.bam.view()
    qualimap(star.out.bam)

    if (params.run_salmon) {
        salmon(trim_galore.out.trim_reads)
        multiqc(qualimap.out.qualimap_out.mix(sortMeRNA.out.sortMeRNA_out, salmon.out.salmon_out).collect())
    } else {
        multiqc( qualimap.out.qualimap_out.mix(sortMeRNA.out.sortMeRNA_out).collect() )
    }

    if (params.run_tpm_calculator) {
        tpm_calculator(star.out.bam)
    }
}

workflow.onComplete {
	println ( workflow.success ? "\nDone!" : "Oops .. something went wrong" )
}
