#Package- merge VCF files and run pileup for SNP and exonerate for indels

package Sanger::CGP::Vaf::Data::ReadVcf; 
##########LICENCE############################################################
# Copyright (c) 2016 Genome Research Ltd.
# 
# Author: Cancer Genome Project cgpit@sanger.ac.uk
# 
# This file is part of cgpVAF.
# 
# cgpVAF is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation; either version 3 of the License, or (at your option) any
# later version.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.
##########LICENCE##############################################################

BEGIN {
  $SIG{__WARN__} = sub {warn $_[0] unless(($_[0] =~ m/^Odd number of elements in hash assignment/) || ($_[0] =~m/^Use of uninitialized value \$gtype/) || ($_[0] =~ m/^Use of uninitialized value \$buf/)|| ($_[0] =~ m/symlink exists/) || ($_[0] =~ m/gzip: stdout: Broken pipe/) )};

};

use strict;
use Vcf;
use Data::Dumper;
use English;
use FindBin qw($Bin);
use List::Util qw(first reduce max min);
use warnings FATAL => 'all';
use Capture::Tiny qw(:all);
use Const::Fast qw(const);
use Carp;
use Try::Tiny qw(try catch finally);
use File::Remove qw(remove);
use File::Path qw(remove_tree);

use Bio::DB::HTS;
use Bio::DB::HTS::Constants;
use Sanger::CGP::Vaf::VafConstants;
use Sanger::CGP::Vaf::Process::Variant;

use Log::Log4perl;
Log::Log4perl->init("$Bin/../config/log4perl.vaf.conf");
my $log = Log::Log4perl->get_logger(__PACKAGE__);

use base qw(Sanger::CGP::Vaf::Data::AbstractVcf);

const my $SORT_N_BGZIP => q{vcf-sort %s| bgzip -c >%s };
const my $TABIX_FILE => q{tabix -f -p vcf %s};
const my $VALIDATE_VCF => q{vcf-validator -u %s};


1; 



sub _localInit {
	my $self=shift;
	$self->_isValid();
} 

sub _isValid {
	my $self=shift;
	$log->logcroak("Input folder must be specified") unless(defined $self->{_d} && -e $self->{_g});
	$log->logcroak("varinat type must be specified") unless(defined $self->{_a});
	$log->logcroak("Tumour sample name(s) must be specified") unless(defined $self->{_tn});
	$log->logcroak("Normal sample name must be specified") unless(defined $self->{_nn});
	$log->logcroak("vcf file extension with dot(.) must be specified") unless(defined $self->{_e});
	$log->logcroak("Genome must be specified") unless(defined $self->{_g} && -e $self->{_g});
	return 1;
}


=head2 getVcfHeaderData
get header info from vcf file
Inputs
=over 2
=back
=cut


sub getVcfHeaderData {
my ($self)=@_;
	$self->_getData();
	my $tumour_count=0;
	my $info_tag_val=undef;
	my $updated_info_tags=undef;
	my $vcf_normal_sample=undef;
	my $vcf_file_obj=undef;
	foreach my $sample (keys %{$self->{'vcf'}}) {
		$tumour_count++;
		if(-e $self->{'vcf'}{$sample}) {	
			my $vcf = Vcf->new(file => $self->{'vcf'}{$sample});
			$vcf->parse_header();	
			$vcf->recalc_ac_an(0);
		
			($info_tag_val,$vcf_normal_sample,$updated_info_tags)=$self->_getOriginalHeader($vcf,$info_tag_val,$vcf_normal_sample,$tumour_count,$sample,$updated_info_tags);
			$vcf->close();
			$vcf_file_obj->{$sample}=$vcf;
		}
		else {
		$self->{'noVcf'}{$sample}=0;
		$vcf_file_obj->{$sample}=0;
		}
		
	}	
	
	if($self->{'_bo'} and ($self->{'_bo'} == 0)) { 
		$log->debug("WARNING!!! more than one normal sample detected for this group".$self->_print_hash($vcf_normal_sample)) if scalar keys %$vcf_normal_sample > 1;
		$self->_checkNormal($vcf_normal_sample);
	}	
		
	if($self->{'_b'}) { 
		$info_tag_val=$self->_populateBedHeader($info_tag_val);
	}
		return ($info_tag_val,$updated_info_tags,$vcf_file_obj);
}



=head2 _checkNormal
check normal sample
Inputs
=over 2
=item vcf_normal -normal sample defined in vcf header
=back
=cut

sub _checkNormal {
	my($self,$vcf_normal)=@_;
	foreach my $key (keys %$vcf_normal) {
		if($key eq $self->getNormalName) {
			$log->debug("User provided normal sample matches with VCF normal");
		}
		else{
			$log->debug("User provided normal sample doesn't matche with normal samples defined in VCF header");
		}
	}	
}

=head2 getProgress
get analysis progress log
Inputs
=over 2
=back
=cut

sub getProgress {
	my($self)=shift;
	print "\n >>>>>> To view overall progress log please check vcfcommons.log file created in the current directory >>>>>>>>>\n";
	print "\n >>>>>> Samples specific progress.out file is created in the output directory : $self->{'_o'} >>>>>>>>>\n";
	my $progress_fhw;
	my $file_name=$self->{'_tmp'}.'/progress.out';
	if (-e $file_name)
	{
		open $progress_fhw, '>>', $file_name or die "Can't open $file_name: $!";
	}
	else{
		open $progress_fhw, '>', $file_name or die "Unable to create progress file $file_name: $!";
	}
	open my $progress_fhr, '<', $file_name or die "Can't open $file_name: $!";
	my @progress_data=<$progress_fhr>;
	close($progress_fhr);
	
	return($progress_fhw,\@progress_data);
}


=head2 _populateBedHeader
add bed info to vcf header 
Inputs
=over 2
=item info_tag_val -vcf info tag object
=back
=cut


sub _populateBedHeader {
	my ($self,$info_tag_val)=@_;
	my $bed_file=$self->{'_b'};
	my $bed_name=$self->_trim_file_path($bed_file);
	my %info_tag;
	$info_tag{'Interval'}='BedFile';
	# create header for bed only locations...
	if( !defined $self->{'vcf'} && $self->{'_ao'}==0 ) {
		my ($vcf_filter,$vcf_info,$vcf_format)=$self->_getCustomHeader();
			foreach my $key (sort keys %$vcf_info) {
			push(@$info_tag_val,$vcf_info->{$key});
		}
		foreach my $key (sort keys %$vcf_format) {
			push(@$info_tag_val,$vcf_format->{$key});
		}
		foreach my $key (sort keys %$vcf_filter) {
			push(@$info_tag_val,$vcf_filter->{$key});
		}
	}
	my %bed_vcf_info=(key=>'FILTER',ID=>'BD', Description=>"Location from bed file");
	push(@$info_tag_val,\%bed_vcf_info);
	
	return $info_tag_val;
}


=head2 writeFinalFileHeaders
create sample specific file handlers to write VAF output in tsv and vcf format 
Inputs
=over 2
=item info_tag_val -vcf info tag object
=back
=cut


sub writeFinalFileHeaders {
	my($self,$info_tag_val,$tags)=@_;
	
	my $WFH_VCF=undef;
	my $WFH_TSV=undef;
  my $outfile_name=$self->getOutputDir.'/'.$self->getNormalName.'_'.@{$self->getTumourName}[0].'_'.$self->{'_a'}.'_vaf';	
	# return if no VCF file found or augment only option is provided for indel data ...
	return if((!defined $self->{'vcf'} && !defined $self->{'_b'}) || ( $self->{'_ao'} == 1) || (-e "$outfile_name.vcf.gz")); 
	my ($vcf)=$self->_getVCFObject($info_tag_val);
	#my $outfile_name=$self->getOutputDir.'/'.$self->getNormalName.'_'.@{$self->getTumourName}[0].'_'.$self->{'_a'}.'_vaf';	
	$log->debug("VCF outfile:$outfile_name.vcf");
	$log->debug("TSV outfile:$outfile_name.tsv");
	open($WFH_VCF, '>',"$outfile_name.vcf") unless(-e "$outfile_name.vcf.gz");
	open($WFH_TSV, '>',"$outfile_name.tsv") unless(-e "$outfile_name.tsv");
	print $WFH_VCF $vcf->format_header();	
  # writing results in tab separated format
	my $tmp_file=$self->{'_tmp'}.'/temp.vcf';
	open(my $tmp_vcf,'>',$tmp_file);
	print $tmp_vcf $vcf->format_header();
	close($tmp_vcf);

	my($col_names,$header,$format_col)=$self->_get_tab_sep_header($tmp_file);
	my $temp_cols=$col_names->{'cols'};
		
	foreach my $sample(@{$self->{'allSamples'}}){
		foreach my $tag_name(@$tags){
			push ($temp_cols,"$sample\_$tag_name");
		}
	}   
	print $WFH_TSV "@$header\n".join("\t",@$temp_cols)."\n";
	$vcf->close();
	close $WFH_VCF;
	close $WFH_TSV;
	return ($outfile_name);
}


=head2 getChromosomes
get chromosome names from genome file
Inputs
=over 2
=back
=cut

sub getChromosomes {
	my($self)=shift;
	my $chromosomes;
	open my $fai_fh , '<', $self->{'_g'}.'.fai';
	while (<$fai_fh>) {
		next if ($_=~/^#/);
		my($chr,$pos)=(split "\t", $_)[0,1];
		push(@$chromosomes,$chr);
	}
	return $chromosomes;
}


=head2 getMergedLocations
get merged snp/indel locations for a given individual group
Inputs
=over 2
=item 
=item chr_location -chromosome or an interval on chromosome
=item updated_info_tags -vcf info tag object
=item vcf_file_obj -vcf file object
=back
=cut

sub getMergedLocations {
	my($self,$chr_location,$updated_info_tags,$vcf_file_obj)=@_;
	my $read_depth=0;
	my $data_for_all_samples=undef;
	my $info_data=undef;
	my $unique_locations=undef;
	if(defined $self->{'_bo'} && $self->{'_bo'}==1) {
		$log->debug("Selected BedOnly analysis skipping data from VCF files");
		return;
	}
	
	foreach my $sample (keys %$vcf_file_obj) {
			my $vcf=$vcf_file_obj->{$sample};
			$vcf->open(region => $chr_location);
			my $count=0;
			while (my $x=$vcf->next_data_array()) {
				# test
				#last if $count > 10;
				#$count++;
				##
				if(defined $self->{'_t'}){
					$info_data=$self->_getInfo($vcf,$$x[7],$updated_info_tags);
				}
				#location key consists of CHR:POS:REF:ALT
				my $location_key="$$x[0]:$$x[1]:$$x[3]:$$x[4]";
				if(defined $self->{'_p'}) {
					$read_depth=$self->_getReadDepth($vcf,$x);
				}
				$data_for_all_samples->{$sample}{$location_key}={'INFO'=>$info_data, 'FILTER'=>$$x[6],'RD'=>$read_depth };																																																																												
				if(!exists $unique_locations->{$location_key}) {
					$unique_locations->{$location_key}="$sample-$$x[6]";
				}
				else{
					$unique_locations->{$location_key}.=':'."$sample-$$x[6]";
				}
			}	
	}
	return ($data_for_all_samples,$unique_locations);
}

=head2 _getData
check and get user provided data and populate respective hash values
Inputs
=over 2
=back
=cut

sub _getData {
	my $self=shift;
	my $count=0;
	foreach my $sample (@{$self->getTumourName}) {
		if( -e ${$self->getTumourBam}[$count] ) {
			$self->{'bam'}{$sample}=${$self->getTumourBam}[$count];
		}
		else {
			$log->debug("Skipping analysis, unble to find TUMOUR BAM file for sample: ".$sample);
		}
		if(${$self->getVcfFile}[$count] &&  -e ${$self->getVcfFile}[$count]) {
			$self->{'vcf'}{$sample}=${$self->getVcfFile}[$count];
		}
		elsif(${$self->{'_vcf'}}[$count] && -e $self->{'_d'}.'/'.${$self->{'_vcf'}}[$count] ) {
			$self->{'vcf'}{$sample}=$self->{'_d'}.'/'.${$self->{'_vcf'}}[$count];
			$log->debug("No default VCF file found, using user defined VCF: ".$self->{'vcf'}{$sample});
		}
		elsif(defined $self->{'_bo'} && $self->{'_bo'}==0 ) {
			$log->logcroak("Unble to find VCF file for sample: ".$sample);
		}	
		$count++;	
	}
	if(!-e $self->getNormalBam) {
		$log->logcroak("Unble to find NORMAL BAM file for sample");
	}
	$self->{'bam'}{$self->getNormalName}=$self->getNormalBam;
		
}

=head2 _getOriginalHeader
parse VCF header and get data from old header lines
Inputs
=over 2
=item vcf - vcf object
=item info_tag_val - hash to store data as perl VCF header specifications 
declared in get_unique_locations so that samples names for each VCF were stored
=item info_tags -user defined annotation tags to be included in the INFO field [e.g Vagrent annotations]
=item norma_sample -name of the normal sample to be stored 
=item tumour_count -counter to increment tumour sample name in header
=back
=cut

sub _getOriginalHeader {
	my ($self,$vcf,$info_tag_val,$normal_sample,$tumour_count,$sample,$updated_info_tags)=@_;
	#stores hash key data in an array for header tags...
	if ($tumour_count == 1){
		my ($vcf_filter,$vcf_info,$vcf_format)=$self->_getCustomHeader();
		#add contig info
		my $contig_info=$vcf->get_header_line(key=>'contig');
		foreach my $contig_line ( @$contig_info) {
			foreach my $chr (sort keys %$contig_line) {
				push(@$info_tag_val,$contig_line->{$chr});
			}
		}
		# get user defined tags
		if(defined $self->{'_t'}) {
			foreach my $tag (split(",",$self->{'_t'})) {
				my $line=$vcf->get_header_line(key=>'INFO', ID=>$tag);
				if(@$line > 0) {
					push (@$updated_info_tags,$tag);
				}
				push(@$info_tag_val,@$line);
			}
		}
		#add custom info
		foreach my $key (sort keys %$vcf_info) {
			push(@$info_tag_val,$vcf_info->{$key});
		}
		
		#add old FILTER
		my $filter_info=$vcf->get_header_line(key=>'FILTER');
		#$filter_info->{(key='FILTER_OLD')}=delete $filter_info->{(key='FILTER')} 
		foreach my $filter_info ( @$filter_info) {
			foreach my $filter_id (sort keys %$filter_info) {
					foreach my $key (keys %{$filter_info->{$filter_id}}) {
						if($filter_info->{$filter_id}{$key} eq 'FILTER') {
							$filter_info->{$filter_id}{$key}='ORIGINAL_FILTER';
						}
					}
				push(@$info_tag_val,$filter_info->{$filter_id});
			}
		}
		#add custom filter
		foreach my $key (sort keys %$vcf_filter) {
			push(@$info_tag_val,$vcf_filter->{$key});
		}
		#add format
		#add custom filter
		foreach my $key (sort keys %$vcf_format) {
			push(@$info_tag_val,$vcf_format->{$key});
		}
	}
	#add samples from old header
	my $header_sample=$vcf->get_header_line(key=>'SAMPLE');
	foreach my $header_sample_line (@$header_sample) {
		foreach my $sample_data (sort keys %$header_sample_line) {
			if($sample_data eq "TUMOUR") {
				$header_sample_line->{'TUMOUR'}{'ID'}="TUMOUR$tumour_count";
			}	
		push(@$info_tag_val,$header_sample_line->{$sample_data});
		}
	}
	#add sample names..
	my $sample_info=$vcf->get_header_line(key=>'SAMPLE', ID=>'NORMAL');
	foreach my $sample_line ( @$sample_info) {
		foreach my $key (keys %$sample_line) {
			if(defined $sample_line->{$key} and $key eq "SampleName") {
				$normal_sample->{$sample_line->{$key}}.="|$sample";
			}
		}		
	}	
return($info_tag_val,$normal_sample,$updated_info_tags);
}


=head2 _getCustomHeader
stores custom VCF header information as per VCF specifications
Inputs
=over 2
=item vcf_filter - hash created to store FILTER field
=item vcf_info - hash created to store INFO field
=item vcf_foramt - hash created to store FORMAT field
=back
=cut

sub _getCustomHeader {
	my ($self)=shift;
	my ($vcf_filter,$vcf_info,$vcf_format);
  my ($log_key,$process_param)=$self->_getProcessLog();
  $vcf_format->{'process_log'}={(key=>$log_key,
			InputVCFSource => _trim_file_path($0),
			InputVCFVer => $Sanger::CGP::Vaf::VafConstants::VERSION,
			InputVCFParam =>$process_param )};

  $vcf_filter->{'filter1'}={(key=>'FILTER',ID=>'1',Description=>"New filter status 1=not called in any")}; # use of 0 is not allowed in FILTER column
	$vcf_filter->{'filter2'}={(key=>'FILTER',ID=>'2',Description=>"New filter status 2=called in any")};
	$vcf_filter->{'filter3'}={(key=>'FILTER',ID=>'3',Description=>"New filter status 3=called + passed")};	
        
	$vcf_info->{'NS'}={(key=>'INFO',ID=>'NS',Number=>'1',Type=>"Integer",Description=>"Number of samples analysed [Excludes designated normal sample]")}; 
	$vcf_info->{'NC'}={(key=>'INFO',ID=>'NC',Number=>'1',Type=>"Integer",Description=>"Number of samples where variant originally Called [Excludes designated normal sample]")};
	$vcf_info->{'NP'}={(key=>'INFO',ID=>'NP',Number=>'1',Type=>"Integer",Description=>"Number of samples where variant Passed the Filter [Excludes designated normal sample]")};
	$vcf_info->{'ND'}={(key=>'INFO',ID=>'ND',Number=>'1',Type=>"Integer",Description=>"Number of samples where sequencing Depth[>0 reads] found [Excludes designated normal sample]")};
	$vcf_info->{'NA'}={(key=>'INFO',ID=>'NA',Number=>'1',Type=>"Integer",Description=>"Number of samples where original algorithm is run [Excludes designated normal sample]")};
	$vcf_info->{'NVD'}={(key=>'INFO',ID=>'NVD',Number=>'1',Type=>"Integer",Description=>"Number of samples where sequencing depth[>0 reads] found for variant reads[Excludes designated normal sample]")};
	
	$vcf_format->{'MTR'}={(key=>'FORMAT',ID=>'MTR', Number=>'1',Type=>'Integer',Description=>"Reads reporting the variant allele")};
	$vcf_format->{'WTR'}={(key=>'FORMAT',ID=>'WTR', Number=>'1',Type=>'Integer',Description=>"Reads reporting the reference allele")};
	$vcf_format->{'DEP'}={(key=>'FORMAT',ID=>'DEP', Number=>'1',Type=>'Integer',Description=>"Total reads covering this position (for subs del positions should be ignored)")};
	$vcf_format->{'MDR'}={(key=>'FORMAT',ID=>'MDR', Number=>'1',Type=>'Integer',Description=>"Variant allele read directions 0=no reads; 1=Forward; 2=Reverse; 3=Forward + Reverse")};
	$vcf_format->{'WDR'}={(key=>'FORMAT',ID=>'WDR', Number=>'1',Type=>'Integer',Description=>"Reference allele read directions 0=no reads; 1=Forward; 2=Reverse; 3=Forward + Reverse")};
	$vcf_format->{'VAF'}={(key=>'FORMAT',ID=>'VAF', Number=>'1',Type=>'Float',Description=>"Variant Allele Fraction (excludes ambiguous:AMB and unknown:UNK reads if any)")};
	$vcf_format->{'OFS'}={(key=>'FORMAT',ID=>'OFS', Number=>'1',Type=>'String',Description=>"Original filter status as defined in input vcf FILTER field")};

	if ($self->{'_a'} eq 'indel') {
		$vcf_format->{'AMB'}={(key=>'FORMAT',ID=>'AMB', Number=>'1',Type=>'Integer',Description=>"Reads mapping on both the alleles with same specificity")};
		$vcf_format->{'UNK'}={(key=>'FORMAT',ID=>'UNK', Number=>'1',Type=>'Integer',Description=>"Reads containing mismatch in the variant position and don't align to ref as first hit")};
	}
	
	if ($self->{'_a'} eq 'snp') {
		$vcf_format->{'FAZ'}={(key=>'FORMAT',ID=>'FAZ', Number=>'1',Type=>'Integer',Description=>"Reads presenting A for this position, forward strand")};
		$vcf_format->{'FCZ'}={(key=>'FORMAT',ID=>'FCZ', Number=>'1',Type=>'Integer',Description=>"Reads presenting C for this position, forward strand")};
		$vcf_format->{'FGZ'}={(key=>'FORMAT',ID=>'FGZ', Number=>'1',Type=>'Integer',Description=>"Reads presenting G for this position, forward strand")};
		$vcf_format->{'FTZ'}={(key=>'FORMAT',ID=>'FTZ', Number=>'1',Type=>'Integer',Description=>"Reads presenting T for this position, forward strand")};
		$vcf_format->{'RAZ'}={(key=>'FORMAT',ID=>'RAZ', Number=>'1',Type=>'Integer',Description=>"Reads presenting A for this position, reverse strand")};
		$vcf_format->{'RCZ'}={(key=>'FORMAT',ID=>'RCZ', Number=>'1',Type=>'Integer',Description=>"Reads presenting C for this position, reverse strand")};
		$vcf_format->{'RGZ'}={(key=>'FORMAT',ID=>'RGZ', Number=>'1',Type=>'Integer',Description=>"Reads presenting G for this position, reverse strand")};
		$vcf_format->{'RTZ'}={(key=>'FORMAT',ID=>'RTZ', Number=>'1',Type=>'Integer',Description=>"Reads presenting T for this position, reverse strand")};	
		$vcf_format->{'VAF'}={(key=>'FORMAT',ID=>'VAF', Number=>'1',Type=>'Float',Description=>"Variant Allele Fraction (excludes ambiguous reads if any)")};

	}
	
	return ($vcf_filter,$vcf_info,$vcf_format);
}

=head2 _getProcessLog
get process log to write in vcf header
Inputs
=over 2
=back
=cut
sub _getProcessLog {
	my ($self)=@_;
	my $hash=$self->{'options'};
	my ($date, $stderr, $exit) = capture {system("date +\"%Y%m%d\"")};
        chomp $date;
        my $log_key=join("_",'vcfProcessLog',$date);
        my $process_log;
	foreach my $key (sort keys %$hash) {
		if(defined $hash->{$key})
		{   
		   chomp $hash->{$key};
       my $val=$hash->{$key};
       
       if (ref($val) eq 'ARRAY') {
       	$val="@$val";
       }
      	if($val){
		   		$process_log->{$key}=$self->_trim_file_path($val);	
		   	}
		}
	}
return ($log_key,$process_log);
}

=head2 _trim_file_path
trim path to write in process log
Inputs
=over 2
=item string -full path string

=back
=cut

sub _trim_file_path{
	my ($self,$string ) = @_;
	
	return 'NA' unless (defined $string);
	
	my @bits = (split("/", $string));
	return pop @bits;
}

=head2 _getInfo
parse VCF INFO line for given locations and returns values for respective tags
Inputs 
=over 2
=item vcf - vcf object
=item INFO - VCF INFO filed value
=item INFO - INFO field tags defined in header 
=back
=cut
sub _getInfo {
	my ($self,$vcf,$INFO,$info_tags)=@_;
	my %info_data;
	#my @tags=split(',',$info_tags);
	foreach my $tag (@$info_tags) {
		my $info_val = $vcf->get_info_field($INFO,$tag);
		if($info_val) {
			$info_data{$tag}=$info_val;
		}
		else {
			$info_data{$tag}='-';
		}
	}
	return \%info_data;
}


=head2 _getReadDepth
get read depth for given variant site for underlying sample
line[8] is format field, get index of tag used for depth e.g., NR(reads on -ve strand) and  PR (reads on +ve strand)
once we had index get value for given tag in the tumour sample
Inputs
=over 2
=item vcf 	-- vcf object
=item line 	-- vcf line for give location
=item tags 	--user specified tags that account for total read depth
=back
=cut

sub	_getReadDepth {
	my ($self,$vcf,$line)=@_;
	my @tags=split(',',$self->{'_p'});
	my $depth=0;
	for my $tag (@tags) {
		my $idx = $vcf->get_tag_index($$line[8],$tag,':'); 
		my $pl  = $vcf->get_field($$line[10],$idx) unless $idx==-1;
		$depth+=$pl;
	}
 return $depth;
} 

=head2 getBedHash
create has for user defined bed locations
Inputs
=over 2
=back
=cut


sub getBedHash {
	my($self)=@_;
	my $bed_locations=undef;
	return if(!defined $self->{'_b'});
  open my $bedFH, '<', $self->{'_b'} || $log->logcroak("unable to open file $!");
  my $bed_name=$self->_trim_file_path($self->{'_b'});
  while(<$bedFH>) {
		chomp;
		next if $_=~/^#/;
		my $fields=split("\t",$_);
		if ($fields < 3) { 
			$log->debug("Not a valid bed location".$_); 
			next;
		}
		my $location_key=join(":",split("\t",$_));
		$bed_locations->{$location_key}="$bed_name-BEDFILE";
	}
	return $bed_locations;
}


=head2 filterBedLocations
Filter bed locations present in vcf file
Inputs
=over 2
=item unique_locations -union of locations created by merging vcf files  
=item bed_locations -hash of bed locations
=back
=cut
sub filterBedLocations {
	my ($self,$unique_locations,$bed_locations)=@_;
		my $filtered_bed_locations=undef;
	  foreach my $location_key (keys %$bed_locations) {
	   	if(exists $unique_locations->{$location_key}) {
	   		$log->debug("Bed location not added to merged location, it is already part of VCF file");
	   	}
	   	else {
	   		$filtered_bed_locations->{$location_key}=$bed_locations->{$location_key};		
	   	}
	  }
	  return $filtered_bed_locations;
}

=head2 populateBedLocations
Populate bed locations for all the samples
Inputs
=over 2
=item filtered_bed_locations -Filtered bed locations present in vcf file  
=item updated_info_tags -INFO tags for bed locations
=back
=cut
sub populateBedLocations {
	my ($self,$filtered_bed_locations,$updated_info_tags)=@_;
	my $temp_tag_val=undef;
	my $data_for_all_samples=undef;
	my $location_counter=0;
	foreach my $tag (@$updated_info_tags) { 
			$temp_tag_val->{$tag}='-';
	}
 	foreach my $location_key (keys %$filtered_bed_locations) {
 			foreach my $sample(keys %{$self->{'vcf'}})	{
			$data_for_all_samples->{$sample}{$location_key}={'INFO'=>$temp_tag_val,'FILTER'=>'NA','RD'=>1 };
		}
		$location_counter++;
	}
	$log->debug(" Added additional ( $location_counter ) locations from BED file");
	return ($data_for_all_samples,$filtered_bed_locations);
}


=head2 processMergedLocations
Analyse merged vcf and/or bed locations
Inputs
=over 2
=item data_for_all_samples -sample specific location information
=item unique_locations -merged unique locations for each individual
=item variant -varinat varinat object containing location specific variant information
=item bam_header_data -header info from BAM file
=item bam_objects -Bio::DB sam object
=item store_results -store results for given chromosome
=item chr -chromosome
=item tags -custom tags
=item info_tag_value -hash containing info tag value
=item progress_fhw -file handler to write progress data
=item progress_data -progress data
=back
=cut

sub processMergedLocations {
	my($self,$data_for_all_samples,$unique_locations,$variant,$bam_header_data,$bam_objects,$store_results,$chr,$tags,$info_tag_val,$progress_fhw,$progress_data)=@_;
	my $pileup_results=undef;
	my $count=0;
	my $total_locations=keys %$unique_locations;
	foreach my $progress_line(@$progress_data) {
		chomp $progress_line;
		if ($progress_line eq "$self->{'_tmp'}/tmp_$chr.vcf" && ($self->{'_ao'} == 0) ) {
			$log->debug("Skipping Analysis for chr:$chr: result file--> $self->{'_tmp'}/tmp_$chr.vcf exists");
			return;
		}
	}
	
	open my $tmp_WFH_VCF, '>', "$self->{'_tmp'}/tmp_$chr.vcf" or $log->logcroak("Unable to create file $!") if($self->{'_ao'} ==0);
	open my $tmp_WFH_TSV, '>', "$self->{'_tmp'}/tmp_$chr.tsv" or $log->logcroak("Unable to create file $!") if($self->{'_ao'} ==0);
	
	
  my($merged_vcf)=$self->_getVCFObject($info_tag_val);
  
  foreach my $location (sort keys %$unique_locations) {
  	#next unless($location=~/114911505/);
		$count++;
		$variant->setLocation($location);
		$variant->setVarLine($unique_locations->{$location});
		my($g_pu)=$variant->formatVarinat();
		#process only passed varinats	
		if($self->{'_r'} && $variant->getVarLine!~/PASS/ && $variant->getVarLine!~/BEDFILE/) {
			if($self->{'_ao'} == 1 || defined $self->{'_m'}) {
				foreach my $sample (@{$self->getTumourName}) {
					$store_results=$variant->storeResults($store_results,$g_pu,$sample);
				}
			}
			next;
		}
    my ($original_vcf_info,$NFS,$original_flag,$max_depth)=$variant->getVcfFields($data_for_all_samples);
    if ($self->{'_a'} eq 'indel') {
			$g_pu=$variant->createExonerateInput($bam_objects->{$self->getNormalName},$bam_header_data,$max_depth,$g_pu);		
    }
    my $mutant_depth=0;
    my $depth=0;
     
  	foreach my $sample (@{$self->{'allSamples'}}) {
   		$g_pu=$variant->populateHash($g_pu,$sample,$bam_header_data); # reset the counter for counts and lib size;		
			if($self->{'_a'} eq 'indel') {	
				$g_pu=$variant->getIndelResults($bam_objects->{$sample},$g_pu);
				if( ($sample eq $self->getNormalName) && (defined $self->{'_m'}) ) {
					$g_pu=$variant->addNormalCount($g_pu);					
				}
				elsif($self->{'_m'} && $data_for_all_samples->{$sample}{$location}) {
					$store_results=$variant->storeResults($store_results,$g_pu,$sample);
				}
			}
			else{
				$g_pu=$variant->getPileup($bam_objects->{$sample},$g_pu);
			}
			if($self->{'_ao'} == 0) {
				my($pileup_line)=$variant->formatResults($original_flag,$g_pu);
				# Mutant read depth found at this location
				if($g_pu->{'sample'} ne $self->getNormalName && $pileup_line->{'MTR'} > 0 ) {
						$mutant_depth++;
				}
				# read depth found at this location 
				if($g_pu->{'sample'} ne $self->getNormalName && $pileup_line->{'DEP'} > 0 ) {
						$depth++;
				}
				$pileup_results->{$g_pu->{'sample'}}=$pileup_line;
			}	
			# feature to test location change
			#if(exists $g_pu->{'new_5p'} && $g_pu->{'sample'} eq $self->getNormalName) {
			#	$log->debug("Updated position : $location: Old[5-3p]:".$g_pu->{'old_5p'}.'-'.$g_pu->{'old_3p'}.'  New[5-3p]:'.$g_pu->{'new_5p'}.'-'.$g_pu->{'new_3p'});
			#}				
  	}# Done with all the samples ...	
  	#get specific annotations from original VCF INFO field....
		if($self->{'_ao'} == 0 ) {
			$original_vcf_info->{'ND'} =	$depth;
			$original_vcf_info->{'NVD'} =	$mutant_depth;
			$self->_writeOutput($original_vcf_info,$NFS,$pileup_results,$tags,$tmp_WFH_VCF,$tmp_WFH_TSV,$g_pu,$merged_vcf);
			$depth=0;
			$mutant_depth=0;
		 }
   if($count % 100 == 0) {
   	$log->debug("Completed:".$count." of total: ".$total_locations." varinats on Chr:".$g_pu->{'chr'});
   }
   
	}# Done with all locations for a chromosome...
	$merged_vcf->close() if defined $merged_vcf;
	# write success file name
	close $tmp_WFH_VCF if($self->{'_ao'} ==0);
	close $tmp_WFH_TSV if($self->{'_ao'} ==0);
	print $progress_fhw "$self->{'_tmp'}/tmp_$chr.vcf\n" if($self->{'_ao'} ==0);
	# returns only when we are augmenting the VCF files else always written into a file 
	return ($store_results);
}

=head2 _get_bam_object
create bam object using Bio::DB::Sam
Inputs
=over 2
=back
=cut

sub _get_bam_object {
	my ($self)=@_;
	my (%bam_objects,%bas_files);
	my $files=$self->{'bam'};
	foreach my $sample (keys %$files) {
		$log->logcroak("Unable to find bam file: $files->{$sample}") unless(-e $files->{$sample});
		my $sam = Bio::DB::HTS->new(-bam => $files->{$sample},
															-fasta =>$self->getGenome,
															-expand_flags => 1);
		$sam->max_pileup_cnt($Sanger::CGP::Vaf::VafConstants::MAX_PILEUP_DEPTH);
		$bam_objects{$sample}=$sam;
		$bas_files{$sample}=$files->{$sample}.'.bas';
	}
	return(\%bam_objects,\%bas_files);
}

=head2 _get_bam_header_data
get_bam_header_data -insert size and chr length
Inputs
=over 2
=item bam_objects -Bio::DB sam object
=item bas_files -bas file to get lib size
=back
=cut

sub _get_bam_header_data {
	my ($self,$bam_objects,$bas_files)=@_;
  return if $self->{'_a'} ne 'indel'; 
  my ($chr_len,%bam_header_data); 
  my $lib_size=0;
  foreach my $key (keys %$bam_objects) {	
  	my($mapped_length)=$self->_get_read_length($bam_objects->{$key});
  	my $read_len=reduce{ $mapped_length->{$a} > $mapped_length->{$b} ? $a : $b } keys %$mapped_length;
   	my $header=$bam_objects->{$key}->header;
   	my $n_targets = $header->n_targets;
   	my $chr_names=$header->target_name;
   	foreach my $chr_no ((0..$n_targets)) {
	 		my $chr_name = $header->target_name->[$chr_no];
	 		my $chr_length = $header->target_len->[$chr_no];
	 		if(defined $chr_name && defined $chr_length)	{
	 			$bam_header_data{$key}{$chr_name}=$chr_length;
	 		}
  	}
  	#get insert size
  	# taken from brass code...
  	my $max=0;
  	my %sample_names = ();
  	foreach (split /\n/, $header->text) {
                next unless /^\@RG.*/;
                if(/.*\tMI:(?:Z:)?(\d+).*/){
                        $max = $1 if $1 > $max;
                        #added to store lib size for all samples..
                        $lib_size=$max if $max > $lib_size;
                }
                $sample_names{$1}++    if(/.*\tSM:([^\t]+).*/);
    }
        $log->warn("Multiple sample names detected ") if scalar keys %sample_names > 1;

        my @names = keys %sample_names;
    # case where MI median inser size tag is absent in BAM file [ use the insert size from bas file ]
    
  	if ($lib_size == 0 ) {$lib_size=$read_len*2};
  	
  	if( -e $bas_files->{$key}) {
  		 $lib_size=$self->_get_lib_size_from_bas($bas_files->{$key});
  	}
  	elsif ($lib_size == 0 )  {
  	  $lib_size=$read_len*2;
  	  $log->debug("No insert size tag in header or no BAS file found for $key using lib size (read_len x 2):$lib_size");
  	}
		$bam_header_data{$key}{'lib_size'}=$lib_size;
		if(defined $read_len) {
			$bam_header_data{$key}{'read_length'}=$read_len;
		}
	}
	return(\%bam_header_data,$lib_size);
}

=head2 _get_lib_size_from_bas
get library size from BAS file
Inputs
=over 2
=item bas_file -bas file name
=back
=cut

sub _get_lib_size_from_bas {
  my ($self,$bas_file)=@_;
	open(my $bas,'<',$bas_file) || $log->logcroak("unable to open file $!");
	my $index_mi=undef;
	my $index_sd=undef;
	my $lib_size=0;
	while (<$bas>) {
					my @array=split(/\t/, $_);
					if (defined $index_mi && $index_sd ) {
					 $lib_size=$array[$index_mi]+ ($array[$index_sd] * 2);
					 last;
					}
					if (!$index_mi && !$index_sd ) {
							$index_mi = first { $array[$_] eq $Sanger::CGP::Vaf::VafConstants::LIB_MEAN_INS_SIZE } 0 .. $#array;
							$index_sd = first { $array[$_] eq $Sanger::CGP::Vaf::VafConstants::LIB_SD } 0 .. $#array;
					}
	}
	close($bas);
	return $lib_size;
}

=head2 _get_read_length
get read length per sample
Inputs
=over 2
=item sam - Bio::DB::Sam objects
=back
=cut

sub _get_read_length {
	my ($self,$sam)=@_;
	my ($mapped_length,$read_counter);
	my $iterator  = $sam->features(-iterator=>1);
		while (my $a = $iterator->next_seq) { 
 			my $qseq=$a->qseq;
 			if(defined $qseq) {
				$read_counter++;
				my $len=length($qseq);
				$mapped_length->{$len}=$read_counter;
				if($read_counter > 1000){
					return $mapped_length;
				}
			}
 		}
}


=head2 WriteAugmentedHeader
write VCF header data
Inputs
=over 2
=back
=cut

sub WriteAugmentedHeader {
	my($self)=@_;
	my $aug_vcf_fh=undef;
	my $aug_vcf_name=undef;
	
	return if(!defined $self->{'vcf'}); 
	
	if(defined $self->{'_m'}) {
		my $augment_vcf=$self->{'vcf'};
		my ($vcf_filter,$vcf_info,$vcf_format)=$self->_getCustomHeader();
		foreach my $sample (keys %$augment_vcf) { 
			my ($tmp_file)=(split '/', $augment_vcf->{$sample})[-1];
			$tmp_file=~s/(\.vcf|\.gz)//g;
			my $aug_vcf=$self->getOutputDir.'/'.$tmp_file.$self->{'_oe'};
			$aug_vcf_name->{$sample}=$aug_vcf;
			open(my $tmp_vcf,'>',$aug_vcf)|| $log->logcroak("unable to open file $!");
			$log->debug("Augmenting vcf file:".$self->getOutputDir."/$tmp_file".$self->{'_oe'});
			my $vcf_aug = Vcf->new(file => $augment_vcf->{$sample});
			$vcf_aug->parse_header();
			#to get all the FORMAT fileds in one group 
			my $tmp_header=$vcf_aug->get_header_line(key=>'FORMAT');
			$vcf_aug->remove_header_line(key=>'FORMAT');
			foreach my $line($tmp_header) {
				foreach my $format_line ( @$line) {
					foreach my $format_field (sort keys %$format_line) {
						$vcf_aug->add_header_line($format_line->{$format_field});
					}
				}
			}	
			
			foreach my $format_type(@Sanger::CGP::Vaf::VafConstants::FORMAT_TYPE) {
					$vcf_aug->add_header_line($vcf_format->{$format_type});
			}
			$vcf_aug->add_header_line($vcf_format->{'process_log'});

			print $tmp_vcf $vcf_aug->format_header();
			$vcf_aug->close();
			$aug_vcf_fh->{$sample}=$tmp_vcf;
		}
	}
    
	if(defined $self->{'_b'} && defined $self->{'_m'}) {
		my $input_bam_files=$self->{'bam'};
		my @bed_header=@Sanger::CGP::Vaf::VafConstants::BED_HEADER_SNP;
		if($self->{'_a'} eq 'indel') {
			@bed_header=@Sanger::CGP::Vaf::VafConstants::BED_HEADER_INDEL;
		}
		foreach my $sample (keys %$input_bam_files) {
			if ($sample ne $self->getNormalName) {
				open(my $tmp_bed,'>',$self->getOutputDir."/$sample.augmented.bed");
				$log->debug("Augmented bed file:".$self->getOutputDir."/$sample.augmented.bed");
				print $tmp_bed join("\t",@bed_header)."\n";
				$aug_vcf_fh->{"$sample\_bed"}=$tmp_bed;	
			}
		}
	}
  return($aug_vcf_fh,$aug_vcf_name);
}

=head2 getVCFObject
write VCF header data
Inputs
=over 2
=item info_tag_val -VCF INFO tag values
=back
=cut

sub _getVCFObject {
	my($self,$info_tag_val)=@_;
	# return if no VCF file found or augment only option is provided for indel data ...
	return if(( !defined $self->{'vcf'} && !defined $self->{'_b'}) || ($self->{'_ao'} == 1));
	my $vcf=Vcf->new();
	my $genome_name=$self->_trim_file_path($self->getGenome);
	my $script_name=$self->_trim_file_path($0);
	$vcf->add_header_line({key=>'reference', value=>$genome_name}); 
	$vcf->add_header_line({key=>'source', value=>$script_name}); 
	$vcf->add_header_line({key=>'script_version', value=>$Sanger::CGP::Vaf::VafConstants::VERSION});
	$vcf->add_header_line({key=>'Date', value=>scalar(localtime)});
	if(defined $info_tag_val) {
		foreach my $hash_val(@$info_tag_val) {
			if(defined $hash_val) {
				$vcf->add_header_line($hash_val);
			}	
		}
	}
	else {
		$log->debug("No data in info Field");
	}
	
	if(!defined $self->{'vcf'}) {
			my $i=0;
			foreach my $sample (@{$self->{'allSamples'}}) {
				if ($sample eq $self->getNormalName) {
					my %temp=(key=>"SAMPLE",ID=>"NO_VCF_NORMAL", Description=>"NO_VCF_DATA", SampleName=>$sample);
					$vcf->add_header_line(\%temp);
				}
				else {
					$i++;
					my %temp=(key=>"SAMPLE",ID=>"NO_VCF_TUMOUR_$i", Description=>"NO_VCF_DATA_$i", SampleName=>$sample);
					$vcf->add_header_line(\%temp);
				}
		}
	}
	$vcf->add_columns(@{$self->{'allSamples'}});
	
	return $vcf;
}
	
=head2 _get_tab_sep_header
parse header data to generate header data and columns names
Inputs
=over 2
=item vcf_header
=back
=cut

sub _get_tab_sep_header {
	my ($self,$vcf_header)=@_;
	my $vcf = Vcf->new(file => $vcf_header);
	$vcf->parse_header();
	my $out;
	my @header;
	push @{$out->{'cols'}}, @$Sanger::CGP::Vaf::VafConstants::BASIC_COLUMN_TITLES;
	for my $i(0..(scalar @$Sanger::CGP::Vaf::VafConstants::BASIC_COLUMN_TITLES) -1){
    push @header, '#'.$Sanger::CGP::Vaf::VafConstants::BASIC_COLUMN_TITLES->[$i] . "\t" . $Sanger::CGP::Vaf::VafConstants::BASIC_COLUMN_DESCS->[$i]."\n";
  }
	my $line_info=$vcf->get_header_line(key=>'INFO');
	foreach my $info_data (@$line_info) {
		foreach my $key (sort keys %$info_data){
			next if ($key eq 'VT' || $key eq 'VC');
			push(@{$out->{'cols'}},$key);
			push @header, '#'.$key. "\t" .$info_data->{$key}{'Description'}."\n";
		}			
	}
	my ($format)=$self->_get_header_lines($vcf->get_header_line(key=>'FORMAT'),'Description','FORMAT');
	push(@header,@$format);
	my ($filter)=$self->_get_header_lines($vcf->get_header_line(key=>'FILTER'),'Description','FILTER');
	push(@header,@$filter);
	my ($org_filter)=$self->_get_header_lines($vcf->get_header_line(key=>'ORIGINAL_FILTER'),'Description','ORIGINAL_FILTER');
	if($org_filter) {
	push(@header,@$org_filter);
	}
	my ($sample)=$self->_get_header_lines($vcf->get_header_line(key=>'SAMPLE'),'SampleName','SAMPLE');
	push(@header,@$sample);
	
return ($out,\@header);

}

=head2 _get_header_lines
parse header data to generate tab file header and columns names
Inputs
=over 2
=item header_line -- specific header line to parse
=item val -- parse specific value from header
=item prefix -header prefix e.g., SAMPLE, FILTER, FORMAT etc.,
=back
=cut

sub _get_header_lines {
	my($self,$header_line,$val,$prefix)=@_;
	my $header;
	foreach my $header_data (@$header_line) {
		foreach my $key (sort keys %$header_data){
			push @$header, '#'.$prefix.'-:'.$key."\t" .$header_data->{$key}{$val}."\n";
		}	
	}	
return $header;
}


=head2 _writeOutput
Write output to files
Inputs
=over 2
=item original_vcf_info - original VCF data
=item NFS - New Filter status
=item new_pileup_results --pileup/exonerate results for given position
=item tags -custom tags
=item WFH_VCF -Vcf Write file handler 
=item WFH_TSV -Tsv Write file handler
=item g_pu -hash containing pielup/exonerate data
=item vcf -VCF object
=back
=cut

sub _writeOutput {
	my ($self,$original_vcf_info,$NFS,$new_pileup_results,$tags,$WFH_VCF,$WFH_TSV,$g_pu,$vcf)=@_;
  if ((!$vcf && !$self->{'_b'})|| ($self->{'_ao'}==1)) {
		return 1;
	}
	
  if (!defined $original_vcf_info) {$original_vcf_info=['.'];}
  my $out;
	$out->{CHROM}  = $g_pu->{'chr'};
	$out->{POS}    = $g_pu->{'start'};
	$out->{ID}     = '.';
	$out->{ALT}    = [$g_pu->{'alt_seq'}];
	$out->{REF}    = $g_pu->{'ref_seq'};
	$out->{QUAL}   = '.';
	$out->{FILTER} = [$NFS];
	## check if field is in header if not use add_info_field...
	$out->{INFO}   = $original_vcf_info;
	$out->{FORMAT} = [@$tags];
	foreach my $sample (@{$self->{'allSamples'}}) {
	  $out->{gtypes}{$sample} = $new_pileup_results->{$sample};
	}
	
	$vcf->format_genotype_strings($out);
	
	# write to VCF at very end.....
	print $WFH_VCF $vcf->format_line($out);
	my ($line)=$self->_parse_info_line($vcf->format_line($out),$original_vcf_info);
	# write to TSV at very end.....
	print $WFH_TSV $self->getNormalName."\t".join("\t",@$line)."\n";
	return 1;
}


=head2 _parse_info_line
parse info line to generate tab sep outfile
Inputs
=over 2
=item vcf_line vcf --line to be parsed
=item original_vcf_info --VCF info field
=back
=cut


sub _parse_info_line {
	my ($self,$vcf_line,$original_vcf_info)=@_;
   # info field prep
		chomp $vcf_line;
    my @data = split "\t", $vcf_line ;

    my (@record,@info_data);

    # basic variant data

    push(@record,$data[2],$data[0],$data[1],$data[3],$data[4],$data[5],$data[6]);

    foreach my $e (split ';',$data[7]){
      push @info_data, [split '=', $e];
    }

    # annotation fields
    my $vdseen = 0;
    foreach my $d (@info_data){
      if($d->[0] eq 'VD'){
        $vdseen = 1;
        my @anno_data = split('\|',$d->[1]);

        foreach my $i(0..4){
          if(defined $anno_data[$i]){
            push(@record,$anno_data[$i]);
          } else {
            push(@record,'-');
          }
        }
      }
    }

    if($vdseen == 0){
      push(@record,'-','-','-','-','-');
    }

    my $vtseen = 0;

		if($vtseen == 0){
      my $ref = $data[3];
      my $alt = $data[4];
      if(length($ref) > 0 && length($alt) > 0){
        if(length($ref) == 1){
          if(length($alt) > 1){
            push(@record,'Ins');
          } else {
            push(@record,'Sub');
          }
        } else {
          if(length($alt) == 1){
            push(@record,'Del');
          } else {
            push(@record,'Complex');
          }
        }
      } else {
        push(@record,'-');
      }

    }

    if($vdseen == 1){
      my $vcseen = 0;
      foreach my $d (@info_data){
        if($d->[0] eq 'VC'){
          $vcseen = 1;
          push(@record,$d->[1]);
        }
      }
      if($vcseen == 0){
        push(@record,'-');
      }
    } else {
      push(@record,'-');
    }

foreach my $info_key (sort keys %$original_vcf_info){
				next if ($info_key eq 'VT' || $info_key eq 'VC');
				if(defined $original_vcf_info->{$info_key}){
         	push(@record,$original_vcf_info->{$info_key});
        }
        else{
        	push(@record,'-');
        }
    }
# print FORMAT field values for each sample

my $i=9; # format field starts from 9
foreach my $sample(@{$self->{'allSamples'}}) {
	push(@record,split(':',$data[$i]));
	$i++;
}    

\@record;

}


=head2 writeResults
Write augmented vcf file
Inputs
=over 2
=item aug_vcf_fh -Augmented vcf file handler
=item store_results -Hash containing results
=item aug_vcf_name -Augmented vcf name
=back
=cut

sub writeResults {
 my ($self, $aug_vcf_fh, $store_results,$aug_vcf_name)= @_;
			foreach my $sample (keys %{$self->{'vcf'}}) {
					$self->_writeFinalVcf($self->{'vcf'}{$sample},$aug_vcf_fh,$sample,$store_results,$aug_vcf_name);
					$aug_vcf_fh->{$sample}->close();
				}
 $log->debug("Completed writing VCF file");
}

=head2 _writeFinalVcf
Write augmented vcf file
Inputs
=over 2
=item vcf_file -vcf file name
=item aug_vcf_fh -Hash of augmented vcf file handlers
=item sample -sample name
=item store_results -Hash containing results
=item aug_vcf_name -Augmented vcf file name hash
=back
=cut

sub _writeFinalVcf {
	  my ($self,$vcf_file,$aug_vcf_fh,$sample,$store_results,$aug_vcf_name)=@_;
	  if ($aug_vcf_fh->{"$sample\_bed"}) {
	      foreach my $key (keys %{$store_results->{"$sample\_bed"}}) {
	   			my $bed_line=$store_results->{"$sample\_bed"}{$key};		
					$aug_vcf_fh->{"$sample\_bed"}->print($bed_line);
				}
	  }
	  my $vcf = Vcf->new(file => $vcf_file);
		$vcf->parse_header();	
		while (my $x = $vcf->next_data_hash()) {
			my $location="$$x{'CHROM'}:$$x{'POS'}:$$x{'REF'}:@{$$x{'ALT'}}[0]";
			my $result_line=$store_results->{$sample}{$location};
			if ($store_results->{$sample}{$location}) { 
				foreach my $format_type(@Sanger::CGP::Vaf::VafConstants::FORMAT_TYPE) {
					$vcf->add_format_field($x,$format_type);
					$$x{gtypes}{'TUMOUR'}{$format_type}=$result_line->{'t'.$format_type};
					$$x{gtypes}{'NORMAL'}{$format_type}=$result_line->{'n'.$format_type};
				}
				$aug_vcf_fh->{$sample}->print($vcf->format_line($x));
			}
	}
		$vcf->close();
		$aug_vcf_fh->{$sample}->close();
		my ($aug_gz,$aug_tabix)=$self->gzipAndIndexVcf($aug_vcf_name->{$sample});
		# remove raw vcf file after tabix indexing
    if ((-e $aug_gz) && (-e $aug_tabix)) {
    	unlink $aug_vcf_name->{$sample} or $log->warn("Could not unlink".$aug_vcf_name->{$sample}.':'.$!) if(-e $aug_vcf_name->{$sample});
    }
		return;
}


=head2 gzipAndIndexVcf
Write bgzip compressed vcf file
Inputs
=over 2
=item annot_vcf file to compress
=back
=cut

sub gzipAndIndexVcf {
	my($self,$annot_vcf)=@_;
	my $command = 'set -o pipefail; ';
	$command.= sprintf $SORT_N_BGZIP, $annot_vcf, $annot_vcf.'.gz; ';
	$command.=sprintf $TABIX_FILE, $annot_vcf.'.gz; ';
	#$command.=sprintf $VALIDATE_VCF, $annot_vcf.'.gz '; # error while testing [ Odd number of elements in hash assignment at $PATH/lib/perl5/Vcf.pm line 2990]
	$command.='2>&1  ';
	$self->_runCommand($command);
  return ($annot_vcf.'.gz', $annot_vcf.'.gz.tbi');
}

=head2 _runCommand
run external command
Inputs
=over 2
=item command to run
=back
=cut

sub _runCommand {
	my($self,$command)=@_;
  try {
      warn "\nErrors from command: $command\n\n";
      print "\nOutput from command: $command\n\n";
      system($command);
  }catch { die $_; };
}

=head2 catFiles
cat files
Inputs
=over 2
=item path -file path
=item ext -file extension
=item outfile -outfile name
=back
=cut
sub catFiles {
	my($self,$path,$ext,$outfile)=@_;
	my $command='cat '.$path.'/tmp_*.'.$ext.' >>'."$outfile.$ext";
  $self->_runCommand($command); # croakable, quiet, no data
}

# recursively cleanups folder and underlying substructure
sub cleanTempdir {
    my ($self,$dir)=@_;
    my $num;
    $log->debug("Unable to find cleanup dir:$dir") if(! -d $dir && $dir!~/^./);
    eval{
    	($num)=remove(\1,"$dir");
    };
    $log->debug("Unable to remove cleanup dir:$dir") if(-d $dir);
    $log->debug("Dir: $dir cleaned successfully");
    return $num;
}


sub check_and_cleanup_dir{
  my ($self,$dir) = @_;
  if(-e $dir && -d $dir){
    my ($dirs, $files) = $self->clear_path($dir);
  }
  return;
}


=head3 clear_path

=over

Implemented as File::Path remove_tree (rmtree)
the idea is to remove the content of all of the directories
and then use remove_tree to remove the directories
needed to handle very big structures from devil

=back

=cut
sub clear_path {
  my ($self, $root_path) = @_;
  my ($dir_count, $file_count) = (0,0);
  my @dirs = ($root_path);
  $dir_count++;
  if((scalar @dirs) > 0) {
    my $curr_path = shift @dirs;
    opendir my $CLEAN, $curr_path or $log->debug("Path does not exist $curr_path");
    while(my $thing = readdir $CLEAN) {
      next if($thing =~ m/^\.{1,2}$/);
      next if($thing =~ m/^\.nfs/);
      #print $thing."\n";
      my $full_path = $curr_path.'/'.$thing;
      if(-d $full_path) {
        push @dirs, $full_path;
        $dir_count++;
      }
      else {
        unlink $full_path or $log->debug("Unable to delete $full_path");
        $file_count++;
      }
    }
    remove_tree($root_path) or $log->debug("Unable to remove $root_path");
    closedir $CLEAN;
  }
  return ($dir_count, $file_count);
}

# generic function
sub _print_hash {
	my ($self,$hash)=@_;
	foreach my $key (sort keys %$hash) {
		if(defined($hash->{$key}))
		{	
			print "$key:==>$hash->{$key}\n";	
		}
	}
}

sub _createSymlink {
  my ($self,$file, $symlink_path)=@_;
  if( -l $symlink_path) { $log->debug("symlink exists, skipping file $symlink_path ==> $file"); return;}
  symlink $file, $symlink_path;
}
