package C4::Members;

# Copyright 2000-2003 Katipo Communications
# Copyright 2010 BibLibre
# Parts Copyright 2010 Catalyst IT
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.


use strict;
#use warnings; FIXME - Bug 2505
use C4::Context;
use C4::Dates qw(format_date_in_iso format_date);
use Digest::MD5 qw(md5_base64);
use String::Random qw( random_string );
use Date::Calc qw/Today Add_Delta_YM check_date Date_to_Days/;
use C4::Log; # logaction
use C4::Overdues;
use C4::Reserves;
use C4::Accounts;
use C4::Biblio;
use C4::Letters;
use C4::SQLHelper qw(InsertInTable UpdateInTable SearchInTable);
use C4::Members::Attributes qw(SearchIdMatchingAttribute);
use C4::NewsChannels; #get slip news
use DateTime;
use DateTime::Format::DateParse;
use Koha::DateUtils;
use Text::Unaccent qw( unac_string );

our ($VERSION,@ISA,@EXPORT,@EXPORT_OK,$debug);

BEGIN {
    $VERSION = 3.07.00.049;
    $debug = $ENV{DEBUG} || 0;
    require Exporter;
    @ISA = qw(Exporter);
    #Get data
    push @EXPORT, qw(
        &Search
        &GetMemberDetails
        &GetMemberRelatives
        &GetMember

        &GetGuarantees

        &GetMemberIssuesAndFines
        &GetPendingIssues
        &GetAllIssues

        &get_institutions
        &getzipnamecity
        &getidcity

        &GetFirstValidEmailAddress
        &GetNoticeEmailAddress

        &GetAge
        &GetCities
        &GetRoadTypes
        &GetRoadTypeDetails
        &GetSortDetails
        &GetTitles

        &GetPatronImage
        &PutPatronImage
        &RmPatronImage

        &GetHideLostItemsPreference

        &IsMemberBlocked
        &GetMemberAccountRecords
        &GetBorNotifyAcctRecord

        &GetborCatFromCatType
        &GetBorrowercategory
        GetBorrowerCategorycode
        &GetBorrowercategoryList

        &GetBorrowersToExpunge
        &GetBorrowersWhoHaveNeverBorrowed
        &GetBorrowersWithIssuesHistoryOlderThan

        &GetExpiryDate

        &AddMessage
        &DeleteMessage
        &GetMessages
        &GetMessagesCount

        &IssueSlip
        GetBorrowersWithEmail
    );

    #Modify data
    push @EXPORT, qw(
        &ModMember
        &changepassword
         &ModPrivacy
    );

    #Delete data
    push @EXPORT, qw(
        &DelMember
    );

    #Insert data
    push @EXPORT, qw(
        &AddMember
        &AddMember_Opac
        &add_member_orgs
        &MoveMemberToDeleted
        &ExtendMemberSubscriptionTo
    );

    #Check data
    push @EXPORT, qw(
        &checkuniquemember
        &checkuserpassword
        &Check_Userid
        &Generate_Userid
        &fixEthnicity
        &ethnicitycategories
        &fixup_cardnumber
        &checkcardnumber
    );
}

=head1 NAME

C4::Members - Perl Module containing convenience functions for member handling

=head1 SYNOPSIS

use C4::Members;

=head1 DESCRIPTION

This module contains routines for adding, modifying and deleting members/patrons/borrowers 

=head1 FUNCTIONS

=head2 Search

  $borrowers_result_array_ref = &Search($filter,$orderby, $limit, 
                       $columns_out, $search_on_fields,$searchtype);

Looks up patrons (borrowers) on filter. A wrapper for SearchInTable('borrowers').

For C<$filter>, C<$orderby>, C<$limit>, C<&columns_out>, C<&search_on_fields> and C<&searchtype>
refer to C4::SQLHelper:SearchInTable().

Special C<$filter> key '' is effectively expanded to search on surname firstname othernamescw
and cardnumber unless C<&search_on_fields> is defined

Examples:

  $borrowers = Search('abcd', 'cardnumber');

  $borrowers = Search({''=>'abcd', category_type=>'I'}, 'surname');

=cut

sub _express_member_find {
    my ($filter) = @_;

    # this is used by circulation everytime a new borrowers cardnumber is scanned
    # so we can check an exact match first, if that works return, otherwise do the rest
    my $dbh   = C4::Context->dbh;
    my $query = "SELECT borrowernumber FROM borrowers WHERE cardnumber = ?";
    if ( my $borrowernumber = $dbh->selectrow_array($query, undef, $filter) ) {
        return( {"borrowernumber"=>$borrowernumber} );
    }

    my ($search_on_fields, $searchtype);
    if ( length($filter) == 1 ) {
        $search_on_fields = [ qw(surname) ];
        $searchtype = 'start_with';
    } else {
        $search_on_fields = [ qw(surname firstname othernames cardnumber) ];
        $searchtype = 'contain';
    }

    return (undef, $search_on_fields, $searchtype);
}

sub Search {
    my ( $filter, $orderby, $limit, $columns_out, $search_on_fields, $searchtype ) = @_;

    my $search_string;
    my $found_borrower;

    if ( my $fr = ref $filter ) {
        if ( $fr eq "HASH" ) {
            if ( my $search_string = $filter->{''} ) {
                my ($member_filter, $member_search_on_fields, $member_searchtype) = _express_member_find($search_string);
                if ($member_filter) {
                    $filter = $member_filter;
                    $found_borrower = 1;
                } else {
                    $search_on_fields ||= $member_search_on_fields;
                    $searchtype ||= $member_searchtype;
                }
            }
        }
        else {
            $search_string = $filter;
        }
    }
    else {
        $search_string = $filter;
        my ($member_filter, $member_search_on_fields, $member_searchtype) = _express_member_find($search_string);
        if ($member_filter) {
            $filter = $member_filter;
            $found_borrower = 1;
        } else {
            $search_on_fields ||= $member_search_on_fields;
            $searchtype ||= $member_searchtype;
        }
    }

    if ( !$found_borrower && C4::Context->preference('ExtendedPatronAttributes') && $search_string ) {
        my $matching_records = C4::Members::Attributes::SearchIdMatchingAttribute($search_string);
        if(scalar(@$matching_records)>0) {
            if ( my $fr = ref $filter ) {
                if ( $fr eq "HASH" ) {
                    my %f = %$filter;
                    $filter = [ $filter ];
                    delete $f{''};
                    push @$filter, { %f, "borrowernumber"=>$$matching_records };
                }
                else {
                    push @$filter, {"borrowernumber"=>$matching_records};
                }
            }
            else {
                $filter = [ $filter ];
                push @$filter, {"borrowernumber"=>$matching_records};
            }
		}
    }

    # $showallbranches was not used at the time SearchMember() was mainstreamed into Search().
    # Mentioning for the reference

    if ( C4::Context->preference("IndependentBranches") ) { # && !$showallbranches){
        if ( my $userenv = C4::Context->userenv ) {
            my $branch =  $userenv->{'branch'};
            if ( ($userenv->{flags} % 2 !=1) && $branch ){
                if (my $fr = ref $filter) {
                    if ( $fr eq "HASH" ) {
                        $filter->{branchcode} = $branch;
                    }
                    else {
                        foreach (@$filter) {
                            $_ = { '' => $_ } unless ref $_;
                            $_->{branchcode} = $branch;
                        }
                    }
                }
                else {
                    $filter = { '' => $filter, branchcode => $branch };
                }
            }      
        }
    }

    if ($found_borrower) {
        $searchtype = "exact";
    }
    $searchtype ||= "start_with";

	return SearchInTable( "borrowers", $filter, $orderby, $limit, $columns_out, $search_on_fields, $searchtype );
}

=head2 GetMemberDetails

($borrower) = &GetMemberDetails($borrowernumber, $cardnumber);

Looks up a patron and returns information about him or her. If
C<$borrowernumber> is true (nonzero), C<&GetMemberDetails> looks
up the borrower by number; otherwise, it looks up the borrower by card
number.

C<$borrower> is a reference-to-hash whose keys are the fields of the
borrowers table in the Koha database. In addition,
C<$borrower-E<gt>{flags}> is a hash giving more detailed information
about the patron. Its keys act as flags :

    if $borrower->{flags}->{LOST} {
        # Patron's card was reported lost
    }

If the state of a flag means that the patron should not be
allowed to borrow any more books, then it will have a C<noissues> key
with a true value.

See patronflags for more details.

C<$borrower-E<gt>{authflags}> is a hash giving more detailed information
about the top-level permissions flags set for the borrower.  For example,
if a user has the "editcatalogue" permission,
C<$borrower-E<gt>{authflags}-E<gt>{editcatalogue}> will exist and have
the value "1".

=cut

sub GetMemberDetails {
    my ( $borrowernumber, $cardnumber ) = @_;
    my $dbh = C4::Context->dbh;
    my $query;
    my $sth;
    if ($borrowernumber) {
        $sth = $dbh->prepare("SELECT borrowers.*,category_type,categories.description,reservefee,enrolmentperiod FROM borrowers LEFT JOIN categories ON borrowers.categorycode=categories.categorycode WHERE  borrowernumber=?");
        $sth->execute($borrowernumber);
    }
    elsif ($cardnumber) {
        $sth = $dbh->prepare("SELECT borrowers.*,category_type,categories.description,reservefee,enrolmentperiod FROM borrowers LEFT JOIN categories ON borrowers.categorycode=categories.categorycode WHERE cardnumber=?");
        $sth->execute($cardnumber);
    }
    else {
        return;
    }
    my $borrower = $sth->fetchrow_hashref;
    my ($amount) = GetMemberAccountRecords( $borrowernumber);
    $borrower->{'amountoutstanding'} = $amount;
    # FIXME - patronflags calls GetMemberAccountRecords... just have patronflags return $amount
    my $flags = patronflags( $borrower);
    my $accessflagshash;

    $sth = $dbh->prepare("select bit,flag from userflags");
    $sth->execute;
    while ( my ( $bit, $flag ) = $sth->fetchrow ) {
        if ( $borrower->{'flags'} && $borrower->{'flags'} & 2**$bit ) {
            $accessflagshash->{$flag} = 1;
        }
    }
    $borrower->{'flags'}     = $flags;
    $borrower->{'authflags'} = $accessflagshash;

    # For the purposes of making templates easier, we'll define a
    # 'showname' which is the alternate form the user's first name if 
    # 'other name' is defined.
    if ($borrower->{category_type} eq 'I') {
        $borrower->{'showname'} = $borrower->{'othernames'};
        $borrower->{'showname'} .= " $borrower->{'firstname'}" if $borrower->{'firstname'};
    } else {
        $borrower->{'showname'} = $borrower->{'firstname'};
    }

    return ($borrower);    #, $flags, $accessflagshash);
}

=head2 patronflags

 $flags = &patronflags($patron);

This function is not exported.

The following will be set where applicable:
 $flags->{CHARGES}->{amount}        Amount of debt
 $flags->{CHARGES}->{noissues}      Set if debt amount >$5.00 (or syspref noissuescharge)
 $flags->{CHARGES}->{message}       Message -- deprecated

 $flags->{CREDITS}->{amount}        Amount of credit
 $flags->{CREDITS}->{message}       Message -- deprecated

 $flags->{  GNA  }                  Patron has no valid address
 $flags->{  GNA  }->{noissues}      Set for each GNA
 $flags->{  GNA  }->{message}       "Borrower has no valid address" -- deprecated

 $flags->{ LOST  }                  Patron's card reported lost
 $flags->{ LOST  }->{noissues}      Set for each LOST
 $flags->{ LOST  }->{message}       Message -- deprecated

 $flags->{DBARRED}                  Set if patron debarred, no access
 $flags->{DBARRED}->{noissues}      Set for each DBARRED
 $flags->{DBARRED}->{message}       Message -- deprecated

 $flags->{ NOTES }
 $flags->{ NOTES }->{message}       The note itself.  NOT deprecated

 $flags->{ ODUES }                  Set if patron has overdue books.
 $flags->{ ODUES }->{message}       "Yes"  -- deprecated
 $flags->{ ODUES }->{itemlist}      ref-to-array: list of overdue books
 $flags->{ ODUES }->{itemlisttext}  Text list of overdue items -- deprecated

 $flags->{WAITING}                  Set if any of patron's reserves are available
 $flags->{WAITING}->{message}       Message -- deprecated
 $flags->{WAITING}->{itemlist}      ref-to-array: list of available items

=over 

=item C<$flags-E<gt>{ODUES}-E<gt>{itemlist}> is a reference-to-array listing the
overdue items. Its elements are references-to-hash, each describing an
overdue item. The keys are selected fields from the issues, biblio,
biblioitems, and items tables of the Koha database.

=item C<$flags-E<gt>{ODUES}-E<gt>{itemlisttext}> is a string giving a text listing of
the overdue items, one per line.  Deprecated.

=item C<$flags-E<gt>{WAITING}-E<gt>{itemlist}> is a reference-to-array listing the
available items. Each element is a reference-to-hash whose keys are
fields from the reserves table of the Koha database.

=back

All the "message" fields that include language generated in this function are deprecated, 
because such strings belong properly in the display layer.

The "message" field that comes from the DB is OK.

=cut

# TODO: use {anonymous => hashes} instead of a dozen %flaginfo
# FIXME rename this function.
sub patronflags {
    my %flags;
    my ( $patroninformation) = @_;
    my $dbh=C4::Context->dbh;
    my ($balance, $owing) = GetMemberAccountBalance( $patroninformation->{'borrowernumber'});
    if ( $owing > 0 ) {
        my %flaginfo;
        my $noissuescharge = C4::Context->preference("noissuescharge") || 5;
        $flaginfo{'message'} = sprintf "Patron owes \$%.02f", $owing;
        $flaginfo{'amount'}  = sprintf "%.02f", $owing;
        if ( $owing > $noissuescharge && !C4::Context->preference("AllowFineOverride") ) {
            $flaginfo{'noissues'} = 1;
        }
        $flags{'CHARGES'} = \%flaginfo;
    }
    elsif ( $balance < 0 ) {
        my %flaginfo;
        $flaginfo{'message'} = sprintf "Patron has credit of \$%.02f", -$balance;
        $flaginfo{'amount'}  = sprintf "%.02f", $balance;
        $flags{'CREDITS'} = \%flaginfo;
    }
    if (   $patroninformation->{'gonenoaddress'}
        && $patroninformation->{'gonenoaddress'} == 1 )
    {
        my %flaginfo;
        $flaginfo{'message'}  = 'Borrower has no valid address.';
        $flaginfo{'noissues'} = 1;
        $flags{'GNA'}         = \%flaginfo;
    }
    if ( $patroninformation->{'lost'} && $patroninformation->{'lost'} == 1 ) {
        my %flaginfo;
        $flaginfo{'message'}  = 'Borrower\'s card reported lost.';
        $flaginfo{'noissues'} = 1;
        $flags{'LOST'}        = \%flaginfo;
    }
    if ( $patroninformation->{'debarred'} && check_date( split( /-/, $patroninformation->{'debarred'} ) ) ) {
        if ( Date_to_Days(Date::Calc::Today) < Date_to_Days( split( /-/, $patroninformation->{'debarred'} ) ) ) {
            my %flaginfo;
            $flaginfo{'debarredcomment'} = $patroninformation->{'debarredcomment'};
            $flaginfo{'message'}         = $patroninformation->{'debarredcomment'};
            $flaginfo{'noissues'}        = 1;
            $flaginfo{'dateend'}         = $patroninformation->{'debarred'};
            $flags{'DBARRED'}           = \%flaginfo;
        }
    }
    if (   $patroninformation->{'borrowernotes'}
        && $patroninformation->{'borrowernotes'} )
    {
        my %flaginfo;
        $flaginfo{'message'} = $patroninformation->{'borrowernotes'};
        $flags{'NOTES'}      = \%flaginfo;
    }
    my ( $odues, $itemsoverdue ) = C4::Overdues::checkoverdues($patroninformation->{'borrowernumber'});
    if ( $odues && $odues > 0 ) {
        my %flaginfo;
        $flaginfo{'message'}  = "Yes";
        $flaginfo{'itemlist'} = $itemsoverdue;
        foreach ( sort { $a->{'date_due'} cmp $b->{'date_due'} }
            @$itemsoverdue )
        {
            $flaginfo{'itemlisttext'} .=
              "$_->{'date_due'} $_->{'barcode'} $_->{'title'} \n";  # newline is display layer
        }
        $flags{'ODUES'} = \%flaginfo;
    }
    my @itemswaiting = C4::Reserves::GetReservesFromBorrowernumber( $patroninformation->{'borrowernumber'},'W' );
    my $nowaiting = scalar @itemswaiting;
    if ( $nowaiting > 0 ) {
        my %flaginfo;
        $flaginfo{'message'}  = "Reserved items available";
        $flaginfo{'itemlist'} = \@itemswaiting;
        $flags{'WAITING'}     = \%flaginfo;
    }
    return ( \%flags );
}


=head2 GetMember

  $borrower = &GetMember(%information);

Retrieve the first patron record meeting on criteria listed in the
C<%information> hash, which should contain one or more
pairs of borrowers column names and values, e.g.,

   $borrower = GetMember(borrowernumber => id);

C<&GetBorrower> returns a reference-to-hash whose keys are the fields of
the C<borrowers> table in the Koha database.

FIXME: GetMember() is used throughout the code as a lookup
on a unique key such as the borrowernumber, but this meaning is not
enforced in the routine itself.

=cut

#'
sub GetMember {
    my ( %information ) = @_;
    if (exists $information{borrowernumber} && !defined $information{borrowernumber}) {
        #passing mysql's kohaadmin?? Makes no sense as a query
        return;
    }
    my $dbh = C4::Context->dbh;
    my $select =
    q{SELECT borrowers.*, categories.category_type, categories.description
    FROM borrowers 
    LEFT JOIN categories on borrowers.categorycode=categories.categorycode WHERE };
    my $more_p = 0;
    my @values = ();
    for (keys %information ) {
        if ($more_p) {
            $select .= ' AND ';
        }
        else {
            $more_p++;
        }

        if (defined $information{$_}) {
            $select .= "$_ = ?";
            push @values, $information{$_};
        }
        else {
            $select .= "$_ IS NULL";
        }
    }
    $debug && warn $select, " ",values %information;
    my $sth = $dbh->prepare("$select");
    $sth->execute(map{$information{$_}} keys %information);
    my $data = $sth->fetchall_arrayref({});
    #FIXME interface to this routine now allows generation of a result set
    #so whole array should be returned but bowhere in the current code expects this
    if (@{$data} ) {
        return $data->[0];
    }

    return;
}

=head2 GetMemberRelatives

 @borrowernumbers = GetMemberRelatives($borrowernumber);

 C<GetMemberRelatives> returns a borrowersnumber's list of guarantor/guarantees of the member given in parameter

=cut 
sub GetMemberRelatives {
    my $borrowernumber = shift;
    my $dbh = C4::Context->dbh;
    my @glist;

    # Getting guarantor
    my $query = "SELECT guarantorid FROM borrowers WHERE borrowernumber=?";
    my $sth = $dbh->prepare($query);
    $sth->execute($borrowernumber);
    my $data = $sth->fetchrow_arrayref();
    push @glist, $data->[0] if $data->[0];
    my $guarantor = $data->[0] ? $data->[0] : undef;

    # Getting guarantees
    $query = "SELECT borrowernumber FROM borrowers WHERE guarantorid=?";
    $sth = $dbh->prepare($query);
    $sth->execute($borrowernumber);
    while ($data = $sth->fetchrow_arrayref()) {
       push @glist, $data->[0];
    }

    # Getting sibling guarantees
    if ($guarantor) {
        $query = "SELECT borrowernumber FROM borrowers WHERE guarantorid=?";
        $sth = $dbh->prepare($query);
        $sth->execute($guarantor);
        while ($data = $sth->fetchrow_arrayref()) {
           push @glist, $data->[0] if ($data->[0] != $borrowernumber);
        }
    }

    return @glist;
}

=head2 IsMemberBlocked

  my ($block_status, $count) = IsMemberBlocked( $borrowernumber );

Returns whether a patron has overdue items that may result
in a block or whether the patron has active fine days
that would block circulation privileges.

C<$block_status> can have the following values:

1 if the patron has outstanding fine days, in which case C<$count> is the number of them

-1 if the patron has overdue items, in which case C<$count> is the number of them

0 if the patron has no overdue items or outstanding fine days, in which case C<$count> is 0

Outstanding fine days are checked before current overdue items
are.

FIXME: this needs to be split into two functions; a potential block
based on the number of current overdue items could be orthogonal
to a block based on whether the patron has any fine days accrued.

=cut

sub IsMemberBlocked {
    my $borrowernumber = shift;
    my $dbh            = C4::Context->dbh;

    my $blockeddate = CheckBorrowerDebarred($borrowernumber);

    return ( 1, $blockeddate ) if $blockeddate;

    # if he have late issues
    my $sth = $dbh->prepare(
        "SELECT COUNT(*) as latedocs
         FROM issues
         WHERE borrowernumber = ?
         AND date_due < now()"
    );
    $sth->execute($borrowernumber);
    my $latedocs = $sth->fetchrow_hashref->{'latedocs'};

    return ( -1, $latedocs ) if $latedocs > 0;

    return ( 0, 0 );
}

=head2 GetMemberIssuesAndFines

  ($overdue_count, $issue_count, $total_fines) = &GetMemberIssuesAndFines($borrowernumber);

Returns aggregate data about items borrowed by the patron with the
given borrowernumber.

C<&GetMemberIssuesAndFines> returns a three-element array.  C<$overdue_count> is the
number of overdue items the patron currently has borrowed. C<$issue_count> is the
number of books the patron currently has borrowed.  C<$total_fines> is
the total fine currently due by the borrower.

=cut

#'
sub GetMemberIssuesAndFines {
    my ( $borrowernumber ) = @_;
    my $dbh   = C4::Context->dbh;
    my $query = "SELECT COUNT(*) FROM issues WHERE borrowernumber = ?";

    $debug and warn $query."\n";
    my $sth = $dbh->prepare($query);
    $sth->execute($borrowernumber);
    my $issue_count = $sth->fetchrow_arrayref->[0];

    $sth = $dbh->prepare(
        "SELECT COUNT(*) FROM issues 
         WHERE borrowernumber = ? 
         AND date_due < now()"
    );
    $sth->execute($borrowernumber);
    my $overdue_count = $sth->fetchrow_arrayref->[0];

    $sth = $dbh->prepare("SELECT SUM(amountoutstanding) FROM accountlines WHERE borrowernumber = ?");
    $sth->execute($borrowernumber);
    my $total_fines = $sth->fetchrow_arrayref->[0];

    return ($overdue_count, $issue_count, $total_fines);
}

sub columns(;$) {
    return @{C4::Context->dbh->selectcol_arrayref("SHOW columns from borrowers")};
}

=head2 ModMember

  my $success = ModMember(borrowernumber => $borrowernumber,
                                            [ field => value ]... );

Modify borrower's data.  All date fields should ALREADY be in ISO format.

return :
true on success, or false on failure

=cut

sub ModMember {
    my (%data) = @_;
    # test to know if you must update or not the borrower password
    if (exists $data{password}) {
        if ($data{password} eq '****' or $data{password} eq '') {
            delete $data{password};
        } else {
            $data{password} = md5_base64($data{password});
        }
    }
	my $execute_success=UpdateInTable("borrowers",\%data);
    if ($execute_success) { # only proceed if the update was a success
        # ok if its an adult (type) it may have borrowers that depend on it as a guarantor
        # so when we update information for an adult we should check for guarantees and update the relevant part
        # of their records, ie addresses and phone numbers
        my $borrowercategory= GetBorrowercategory( $data{'category_type'} );
        if ( exists  $borrowercategory->{'category_type'} && $borrowercategory->{'category_type'} eq ('A' || 'S') ) {
            # is adult check guarantees;
            UpdateGuarantees(%data);
        }
        logaction("MEMBERS", "MODIFY", $data{'borrowernumber'}, "UPDATE (executed w/ arg: $data{'borrowernumber'})") if C4::Context->preference("BorrowersLog");
    }
    return $execute_success;
}


=head2 AddMember

  $borrowernumber = &AddMember(%borrower);

insert new borrower into table
Returns the borrowernumber upon success

Returns as undef upon any db error without further processing

=cut

#'
sub AddMember {
    my (%data) = @_;
    my $dbh = C4::Context->dbh;

    # generate a proper login if none provided
    $data{'userid'} = Generate_Userid($data{'borrowernumber'}, $data{'firstname'}, $data{'surname'}) if $data{'userid'} eq '';

    # add expiration date if it isn't already there
    unless ( $data{'dateexpiry'} ) {
        $data{'dateexpiry'} = GetExpiryDate( $data{'categorycode'}, C4::Dates->new()->output("iso") );
    }

    # add enrollment date if it isn't already there
    unless ( $data{'dateenrolled'} ) {
        $data{'dateenrolled'} = C4::Dates->new()->output("iso");
    }

    # create a disabled account if no password provided
    $data{'password'} = ($data{'password'})? md5_base64($data{'password'}) : '!';
    $data{'borrowernumber'}=InsertInTable("borrowers",\%data);


    # mysql_insertid is probably bad.  not necessarily accurate and mysql-specific at best.
    logaction("MEMBERS", "CREATE", $data{'borrowernumber'}, "") if C4::Context->preference("BorrowersLog");
    
    # check for enrollment fee & add it if needed
    my $sth = $dbh->prepare("SELECT enrolmentfee FROM categories WHERE categorycode=?");
    $sth->execute($data{'categorycode'});
    my ($enrolmentfee) = $sth->fetchrow;
    if ($sth->err) {
        warn sprintf('Database returned the following error: %s', $sth->errstr);
        return;
    }
    if ($enrolmentfee && $enrolmentfee > 0) {
        # insert fee in patron debts
        manualinvoice($data{'borrowernumber'}, '', '', 'A', $enrolmentfee);
    }

    return $data{'borrowernumber'};
}

=head2 Check_Userid

    my $uniqueness = Check_Userid($userid,$borrowernumber);

    $borrowernumber is optional (i.e. it can contain a blank value). If $userid is passed with a blank $borrowernumber variable, the database will be checked for all instances of that userid (i.e. userid=? AND borrowernumber != '').

    If $borrowernumber is provided, the database will be checked for every instance of that userid coupled with a different borrower(number) than the one provided.

    return :
        0 for not unique (i.e. this $userid already exists)
        1 for unique (i.e. this $userid does not exist, or this $userid/$borrowernumber combination already exists)

=cut

sub Check_Userid {
    my ($uid,$member) = @_;
    my $dbh = C4::Context->dbh;
    my $sth =
      $dbh->prepare(
        "SELECT * FROM borrowers WHERE userid=? AND borrowernumber != ?");
    $sth->execute( $uid, $member );
    if ( ( $uid ne '' ) && ( my $row = $sth->fetchrow_hashref ) ) {
        return 0;
    }
    else {
        return 1;
    }
}

=head2 Generate_Userid

    my $newuid = Generate_Userid($borrowernumber, $firstname, $surname);

    Generate a userid using the $surname and the $firstname (if there is a value in $firstname).

    $borrowernumber is optional (i.e. it can contain a blank value). A value is passed when generating a new userid for an existing borrower. When a new userid is created for a new borrower, a blank value is passed to this sub.

    return :
        new userid ($firstname.$surname if there is a $firstname, or $surname if there is no value in $firstname) plus offset (0 if the $newuid is unique, or a higher numeric value if Check_Userid finds an existing match for the $newuid in the database).

=cut

sub Generate_Userid {
  my ($borrowernumber, $firstname, $surname) = @_;
  my $newuid;
  my $offset = 0;
  #The script will "do" the following code and increment the $offset until Check_Userid = 1 (i.e. until $newuid comes back as unique)
  do {
    $firstname =~ s/[[:digit:][:space:][:blank:][:punct:][:cntrl:]]//g;
    $surname =~ s/[[:digit:][:space:][:blank:][:punct:][:cntrl:]]//g;
    $newuid = lc(($firstname)? "$firstname.$surname" : $surname);
    $newuid = unac_string('utf-8',$newuid);
    $newuid .= $offset unless $offset == 0;
    $offset++;

   } while (!Check_Userid($newuid,$borrowernumber));

   return $newuid;
}

sub changepassword {
    my ( $uid, $member, $digest ) = @_;
    my $dbh = C4::Context->dbh;

#Make sure the userid chosen is unique and not theirs if non-empty. If it is not,
#Then we need to tell the user and have them create a new one.
    my $resultcode;
    my $sth =
      $dbh->prepare(
        "SELECT * FROM borrowers WHERE userid=? AND borrowernumber != ?");
    $sth->execute( $uid, $member );
    if ( ( $uid ne '' ) && ( my $row = $sth->fetchrow_hashref ) ) {
        $resultcode=0;
    }
    else {
        #Everything is good so we can update the information.
        $sth =
          $dbh->prepare(
            "update borrowers set userid=?, password=? where borrowernumber=?");
        $sth->execute( $uid, $digest, $member );
        $resultcode=1;
    }
    
    logaction("MEMBERS", "CHANGE PASS", $member, "") if C4::Context->preference("BorrowersLog");
    return $resultcode;    
}



=head2 fixup_cardnumber

Warning: The caller is responsible for locking the members table in write
mode, to avoid database corruption.

=cut

use vars qw( @weightings );
my @weightings = ( 8, 4, 6, 3, 5, 2, 1 );

sub fixup_cardnumber {
    my ($cardnumber) = @_;
    my $autonumber_members = C4::Context->boolean_preference('autoMemberNum') || 0;

    # Find out whether member numbers should be generated
    # automatically. Should be either "1" or something else.
    # Defaults to "0", which is interpreted as "no".

    #     if ($cardnumber !~ /\S/ && $autonumber_members) {
    ($autonumber_members) or return $cardnumber;
    my $checkdigit = C4::Context->preference('checkdigit');
    my $dbh = C4::Context->dbh;
    if ( $checkdigit and $checkdigit eq 'katipo' ) {

        # if checkdigit is selected, calculate katipo-style cardnumber.
        # otherwise, just use the max()
        # purpose: generate checksum'd member numbers.
        # We'll assume we just got the max value of digits 2-8 of member #'s
        # from the database and our job is to increment that by one,
        # determine the 1st and 9th digits and return the full string.
        my $sth = $dbh->prepare(
            "select max(substring(borrowers.cardnumber,2,7)) as new_num from borrowers"
        );
        $sth->execute;
        my $data = $sth->fetchrow_hashref;
        $cardnumber = $data->{new_num};
        if ( !$cardnumber ) {    # If DB has no values,
            $cardnumber = 1000000;    # start at 1000000
        } else {
            $cardnumber += 1;
        }

        my $sum = 0;
        for ( my $i = 0 ; $i < 8 ; $i += 1 ) {
            # read weightings, left to right, 1 char at a time
            my $temp1 = $weightings[$i];

            # sequence left to right, 1 char at a time
            my $temp2 = substr( $cardnumber, $i, 1 );

            # mult each char 1-7 by its corresponding weighting
            $sum += $temp1 * $temp2;
        }

        my $rem = ( $sum % 11 );
        $rem = 'X' if $rem == 10;

        return "V$cardnumber$rem";
     } else {

        my $sth = $dbh->prepare(
            'SELECT MAX( CAST( cardnumber AS SIGNED ) ) FROM borrowers WHERE cardnumber REGEXP "^-?[0-9]+$"'
        );
        $sth->execute;
        my ($result) = $sth->fetchrow;
        return $result + 1;
    }
    return $cardnumber;     # just here as a fallback/reminder 
}

=head2 GetGuarantees

  ($num_children, $children_arrayref) = &GetGuarantees($parent_borrno);
  $child0_cardno = $children_arrayref->[0]{"cardnumber"};
  $child0_borrno = $children_arrayref->[0]{"borrowernumber"};

C<&GetGuarantees> takes a borrower number (e.g., that of a patron
with children) and looks up the borrowers who are guaranteed by that
borrower (i.e., the patron's children).

C<&GetGuarantees> returns two values: an integer giving the number of
borrowers guaranteed by C<$parent_borrno>, and a reference to an array
of references to hash, which gives the actual results.

=cut

#'
sub GetGuarantees {
    my ($borrowernumber) = @_;
    my $dbh              = C4::Context->dbh;
    my $sth              =
      $dbh->prepare(
"select cardnumber,borrowernumber, firstname, surname from borrowers where guarantorid=?"
      );
    $sth->execute($borrowernumber);

    my @dat;
    my $data = $sth->fetchall_arrayref({}); 
    return ( scalar(@$data), $data );
}

=head2 UpdateGuarantees

  &UpdateGuarantees($parent_borrno);
  

C<&UpdateGuarantees> borrower data for an adult and updates all the guarantees
with the modified information

=cut

#'
sub UpdateGuarantees {
    my %data = shift;
    my $dbh = C4::Context->dbh;
    my ( $count, $guarantees ) = GetGuarantees( $data{'borrowernumber'} );
    foreach my $guarantee (@$guarantees){
        my $guaquery = qq|UPDATE borrowers 
              SET address=?,fax=?,B_city=?,mobile=?,city=?,phone=?
              WHERE borrowernumber=?
        |;
        my $sth = $dbh->prepare($guaquery);
        $sth->execute($data{'address'},$data{'fax'},$data{'B_city'},$data{'mobile'},$data{'city'},$data{'phone'},$guarantee->{'borrowernumber'});
    }
}
=head2 GetPendingIssues

  my $issues = &GetPendingIssues(@borrowernumber);

Looks up what the patron with the given borrowernumber has borrowed.

C<&GetPendingIssues> returns a
reference-to-array where each element is a reference-to-hash; the
keys are the fields from the C<issues>, C<biblio>, and C<items> tables.
The keys include C<biblioitems> fields except marc and marcxml.

=cut

#'
sub GetPendingIssues {
    my @borrowernumbers = @_;

    unless (@borrowernumbers ) { # return a ref_to_array
        return \@borrowernumbers; # to not cause surprise to caller
    }

    # Borrowers part of the query
    my $bquery = '';
    for (my $i = 0; $i < @borrowernumbers; $i++) {
        $bquery .= ' issues.borrowernumber = ?';
        if ($i < $#borrowernumbers ) {
            $bquery .= ' OR';
        }
    }

    # must avoid biblioitems.* to prevent large marc and marcxml fields from killing performance
    # FIXME: namespace collision: each table has "timestamp" fields.  Which one is "timestamp" ?
    # FIXME: circ/ciculation.pl tries to sort by timestamp!
    # FIXME: namespace collision: other collisions possible.
    # FIXME: most of this data isn't really being used by callers.
    my $query =
   "SELECT issues.*,
            items.*,
           biblio.*,
           biblioitems.volume,
           biblioitems.number,
           biblioitems.itemtype,
           biblioitems.isbn,
           biblioitems.issn,
           biblioitems.publicationyear,
           biblioitems.publishercode,
           biblioitems.volumedate,
           biblioitems.volumedesc,
           biblioitems.lccn,
           biblioitems.url,
           borrowers.firstname,
           borrowers.surname,
           borrowers.cardnumber,
           issues.timestamp AS timestamp,
           issues.renewals  AS renewals,
           issues.borrowernumber AS borrowernumber,
            items.renewals  AS totalrenewals
    FROM   issues
    LEFT JOIN items       ON items.itemnumber       =      issues.itemnumber
    LEFT JOIN biblio      ON items.biblionumber     =      biblio.biblionumber
    LEFT JOIN biblioitems ON items.biblioitemnumber = biblioitems.biblioitemnumber
    LEFT JOIN borrowers ON issues.borrowernumber = borrowers.borrowernumber
    WHERE
      $bquery
    ORDER BY issues.issuedate"
    ;

    my $sth = C4::Context->dbh->prepare($query);
    $sth->execute(@borrowernumbers);
    my $data = $sth->fetchall_arrayref({});
    my $tz = C4::Context->tz();
    my $today = DateTime->now( time_zone => $tz);
    foreach (@{$data}) {
        if ($_->{issuedate}) {
            $_->{issuedate} = dt_from_string($_->{issuedate}, 'sql');
        }
        $_->{date_due} or next;
        $_->{date_due} = DateTime::Format::DateParse->parse_datetime($_->{date_due}, $tz->name());
        if ( DateTime->compare($_->{date_due}, $today) == -1 ) {
            $_->{overdue} = 1;
        }
    }
    return $data;
}

=head2 GetAllIssues

  $issues = &GetAllIssues($borrowernumber, $sortkey, $limit);

Looks up what the patron with the given borrowernumber has borrowed,
and sorts the results.

C<$sortkey> is the name of a field on which to sort the results. This
should be the name of a field in the C<issues>, C<biblio>,
C<biblioitems>, or C<items> table in the Koha database.

C<$limit> is the maximum number of results to return.

C<&GetAllIssues> an arrayref, C<$issues>, of hashrefs, the keys of which
are the fields from the C<issues>, C<biblio>, C<biblioitems>, and
C<items> tables of the Koha database.

=cut

#'
sub GetAllIssues {
    my ( $borrowernumber, $order, $limit ) = @_;

    my $dbh = C4::Context->dbh;
    my $query =
'SELECT *, issues.timestamp as issuestimestamp, issues.renewals AS renewals,items.renewals AS totalrenewals,items.timestamp AS itemstimestamp
  FROM issues 
  LEFT JOIN items on items.itemnumber=issues.itemnumber
  LEFT JOIN biblio ON items.biblionumber=biblio.biblionumber
  LEFT JOIN biblioitems ON items.biblioitemnumber=biblioitems.biblioitemnumber
  WHERE borrowernumber=? 
  UNION ALL
  SELECT *, old_issues.timestamp as issuestimestamp, old_issues.renewals AS renewals,items.renewals AS totalrenewals,items.timestamp AS itemstimestamp 
  FROM old_issues 
  LEFT JOIN items on items.itemnumber=old_issues.itemnumber
  LEFT JOIN biblio ON items.biblionumber=biblio.biblionumber
  LEFT JOIN biblioitems ON items.biblioitemnumber=biblioitems.biblioitemnumber
  WHERE borrowernumber=? AND old_issues.itemnumber IS NOT NULL
  order by ' . $order;
    if ($limit) {
        $query .= " limit $limit";
    }

    my $sth = $dbh->prepare($query);
    $sth->execute( $borrowernumber, $borrowernumber );
    return $sth->fetchall_arrayref( {} );
}


=head2 GetMemberAccountRecords

  ($total, $acctlines, $count) = &GetMemberAccountRecords($borrowernumber);

Looks up accounting data for the patron with the given borrowernumber.

C<&GetMemberAccountRecords> returns a three-element array. C<$acctlines> is a
reference-to-array, where each element is a reference-to-hash; the
keys are the fields of the C<accountlines> table in the Koha database.
C<$count> is the number of elements in C<$acctlines>. C<$total> is the
total amount outstanding for all of the account lines.

=cut

sub GetMemberAccountRecords {
    my ($borrowernumber) = @_;
    my $dbh = C4::Context->dbh;
    my @acctlines;
    my $numlines = 0;
    my $strsth      = qq(
                        SELECT * 
                        FROM accountlines 
                        WHERE borrowernumber=?);
    $strsth.=" ORDER BY date desc,timestamp DESC";
    my $sth= $dbh->prepare( $strsth );
    $sth->execute( $borrowernumber );

    my $total = 0;
    while ( my $data = $sth->fetchrow_hashref ) {
        if ( $data->{itemnumber} ) {
            my $biblio = GetBiblioFromItemNumber( $data->{itemnumber} );
            $data->{biblionumber} = $biblio->{biblionumber};
            $data->{title}        = $biblio->{title};
        }
        $acctlines[$numlines] = $data;
        $numlines++;
        $total += int(1000 * $data->{'amountoutstanding'}); # convert float to integer to avoid round-off errors
    }
    $total /= 1000;
    return ( $total, \@acctlines,$numlines);
}

=head2 GetMemberAccountBalance

  ($total_balance, $non_issue_balance, $other_charges) = &GetMemberAccountBalance($borrowernumber);

Calculates amount immediately owing by the patron - non-issue charges.
Based on GetMemberAccountRecords.
Charges exempt from non-issue are:
* Res (reserves)
* Rent (rental) if RentalsInNoissuesCharge syspref is set to false
* Manual invoices if ManInvInNoissuesCharge syspref is set to false

=cut

sub GetMemberAccountBalance {
    my ($borrowernumber) = @_;

    my $ACCOUNT_TYPE_LENGTH = 5; # this is plain ridiculous...

    my @not_fines = ('Res');
    push @not_fines, 'Rent' unless C4::Context->preference('RentalsInNoissuesCharge');
    unless ( C4::Context->preference('ManInvInNoissuesCharge') ) {
        my $dbh = C4::Context->dbh;
        my $man_inv_types = $dbh->selectcol_arrayref(qq{SELECT authorised_value FROM authorised_values WHERE category = 'MANUAL_INV'});
        push @not_fines, map substr($_, 0, $ACCOUNT_TYPE_LENGTH), @$man_inv_types;
    }
    my %not_fine = map {$_ => 1} @not_fines;

    my ($total, $acctlines) = GetMemberAccountRecords($borrowernumber);
    my $other_charges = 0;
    foreach (@$acctlines) {
        $other_charges += $_->{amountoutstanding} if $not_fine{ substr($_->{accounttype}, 0, $ACCOUNT_TYPE_LENGTH) };
    }

    return ( $total, $total - $other_charges, $other_charges);
}

=head2 GetBorNotifyAcctRecord

  ($total, $acctlines, $count) = &GetBorNotifyAcctRecord($params,$notifyid);

Looks up accounting data for the patron with the given borrowernumber per file number.

C<&GetBorNotifyAcctRecord> returns a three-element array. C<$acctlines> is a
reference-to-array, where each element is a reference-to-hash; the
keys are the fields of the C<accountlines> table in the Koha database.
C<$count> is the number of elements in C<$acctlines>. C<$total> is the
total amount outstanding for all of the account lines.

=cut

sub GetBorNotifyAcctRecord {
    my ( $borrowernumber, $notifyid ) = @_;
    my $dbh = C4::Context->dbh;
    my @acctlines;
    my $numlines = 0;
    my $sth = $dbh->prepare(
            "SELECT * 
                FROM accountlines 
                WHERE borrowernumber=? 
                    AND notify_id=? 
                    AND amountoutstanding != '0' 
                ORDER BY notify_id,accounttype
                ");

    $sth->execute( $borrowernumber, $notifyid );
    my $total = 0;
    while ( my $data = $sth->fetchrow_hashref ) {
        if ( $data->{itemnumber} ) {
            my $biblio = GetBiblioFromItemNumber( $data->{itemnumber} );
            $data->{biblionumber} = $biblio->{biblionumber};
            $data->{title}        = $biblio->{title};
        }
        $acctlines[$numlines] = $data;
        $numlines++;
        $total += int(100 * $data->{'amountoutstanding'});
    }
    $total /= 100;
    return ( $total, \@acctlines, $numlines );
}

=head2 checkuniquemember (OUEST-PROVENCE)

  ($result,$categorycode)  = &checkuniquemember($collectivity,$surname,$firstname,$dateofbirth);

Checks that a member exists or not in the database.

C<&result> is nonzero (=exist) or 0 (=does not exist)
C<&categorycode> is from categorycode table
C<&collectivity> is 1 (= we add a collectivity) or 0 (= we add a physical member)
C<&surname> is the surname
C<&firstname> is the firstname (only if collectivity=0)
C<&dateofbirth> is the date of birth in ISO format (only if collectivity=0)

=cut

# FIXME: This function is not legitimate.  Multiple patrons might have the same first/last name and birthdate.
# This is especially true since first name is not even a required field.

sub checkuniquemember {
    my ( $collectivity, $surname, $firstname, $dateofbirth ) = @_;
    my $dbh = C4::Context->dbh;
    my $request = ($collectivity) ?
        "SELECT borrowernumber,categorycode FROM borrowers WHERE surname=? " :
            ($dateofbirth) ?
            "SELECT borrowernumber,categorycode FROM borrowers WHERE surname=? and firstname=?  and dateofbirth=?" :
            "SELECT borrowernumber,categorycode FROM borrowers WHERE surname=? and firstname=?";
    my $sth = $dbh->prepare($request);
    if ($collectivity) {
        $sth->execute( uc($surname) );
    } elsif($dateofbirth){
        $sth->execute( uc($surname), ucfirst($firstname), $dateofbirth );
    }else{
        $sth->execute( uc($surname), ucfirst($firstname));
    }
    my @data = $sth->fetchrow;
    ( $data[0] ) and return $data[0], $data[1];
    return 0;
}

sub checkcardnumber {
    my ($cardnumber,$borrowernumber) = @_;
    # If cardnumber is null, we assume they're allowed.
    return 0 if !defined($cardnumber);
    my $dbh = C4::Context->dbh;
    my $query = "SELECT * FROM borrowers WHERE cardnumber=?";
    $query .= " AND borrowernumber <> ?" if ($borrowernumber);
  my $sth = $dbh->prepare($query);
  if ($borrowernumber) {
   $sth->execute($cardnumber,$borrowernumber);
  } else { 
     $sth->execute($cardnumber);
  } 
    if (my $data= $sth->fetchrow_hashref()){
        return 1;
    }
    else {
        return 0;
    }
}  


=head2 getzipnamecity (OUEST-PROVENCE)

take all info from table city for the fields city and  zip
check for the name and the zip code of the city selected

=cut

sub getzipnamecity {
    my ($cityid) = @_;
    my $dbh      = C4::Context->dbh;
    my $sth      =
      $dbh->prepare(
        "select city_name,city_state,city_zipcode,city_country from cities where cityid=? ");
    $sth->execute($cityid);
    my @data = $sth->fetchrow;
    return $data[0], $data[1], $data[2], $data[3];
}


=head2 getdcity (OUEST-PROVENCE)

recover cityid  with city_name condition

=cut

sub getidcity {
    my ($city_name) = @_;
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("select cityid from cities where city_name=? ");
    $sth->execute($city_name);
    my $data = $sth->fetchrow;
    return $data;
}

=head2 GetFirstValidEmailAddress

  $email = GetFirstValidEmailAddress($borrowernumber);

Return the first valid email address for a borrower, given the borrowernumber.  For now, the order 
is defined as email, emailpro, B_email.  Returns the empty string if the borrower has no email 
addresses.

=cut

sub GetFirstValidEmailAddress {
    my $borrowernumber = shift;
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare( "SELECT email, emailpro, B_email FROM borrowers where borrowernumber = ? ");
    $sth->execute( $borrowernumber );
    my $data = $sth->fetchrow_hashref;

    if ($data->{'email'}) {
       return $data->{'email'};
    } elsif ($data->{'emailpro'}) {
       return $data->{'emailpro'};
    } elsif ($data->{'B_email'}) {
       return $data->{'B_email'};
    } else {
       return '';
    }
}

=head2 GetNoticeEmailAddress

  $email = GetNoticeEmailAddress($borrowernumber);

Return the email address of borrower used for notices, given the borrowernumber.
Returns the empty string if no email address.

=cut

sub GetNoticeEmailAddress {
    my $borrowernumber = shift;

    my $which_address = C4::Context->preference("AutoEmailPrimaryAddress");
    # if syspref is set to 'first valid' (value == OFF), look up email address
    if ( $which_address eq 'OFF' ) {
        return GetFirstValidEmailAddress($borrowernumber);
    }
    # specified email address field
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare( qq{
        SELECT $which_address AS primaryemail
        FROM borrowers
        WHERE borrowernumber=?
    } );
    $sth->execute($borrowernumber);
    my $data = $sth->fetchrow_hashref;
    return $data->{'primaryemail'} || '';
}

=head2 GetExpiryDate 

  $expirydate = GetExpiryDate($categorycode, $dateenrolled);

Calculate expiry date given a categorycode and starting date.  Date argument must be in ISO format.
Return date is also in ISO format.

=cut

sub GetExpiryDate {
    my ( $categorycode, $dateenrolled ) = @_;
    my $enrolments;
    if ($categorycode) {
        my $dbh = C4::Context->dbh;
        my $sth = $dbh->prepare("SELECT enrolmentperiod,enrolmentperioddate FROM categories WHERE categorycode=?");
        $sth->execute($categorycode);
        $enrolments = $sth->fetchrow_hashref;
    }
    # die "GetExpiryDate: for enrollmentperiod $enrolmentperiod (category '$categorycode') starting $dateenrolled.\n";
    my @date = split (/-/,$dateenrolled);
    if($enrolments->{enrolmentperiod}){
        return sprintf("%04d-%02d-%02d", Add_Delta_YM(@date,0,$enrolments->{enrolmentperiod}));
    }else{
        return $enrolments->{enrolmentperioddate};
    }
}

=head2 checkuserpassword (OUEST-PROVENCE)

check for the password and login are not used
return the number of record 
0=> NOT USED 1=> USED

=cut

sub checkuserpassword {
    my ( $borrowernumber, $userid, $password ) = @_;
    $password = md5_base64($password);
    my $dbh = C4::Context->dbh;
    my $sth =
      $dbh->prepare(
"Select count(*) from borrowers where borrowernumber !=? and userid =? and password=? "
      );
    $sth->execute( $borrowernumber, $userid, $password );
    my $number_rows = $sth->fetchrow;
    return $number_rows;

}

=head2 GetborCatFromCatType

  ($codes_arrayref, $labels_hashref) = &GetborCatFromCatType();

Looks up the different types of borrowers in the database. Returns two
elements: a reference-to-array, which lists the borrower category
codes, and a reference-to-hash, which maps the borrower category codes
to category descriptions.

=cut

#'
sub GetborCatFromCatType {
    my ( $category_type, $action, $no_branch_limit ) = @_;

    my $branch_limit = $no_branch_limit
        ? 0
        : C4::Context->userenv ? C4::Context->userenv->{"branch"} : "";

    # FIXME - This API  seems both limited and dangerous.
    my $dbh     = C4::Context->dbh;

    my $request = qq{
        SELECT categories.categorycode, categories.description
        FROM categories
    };
    $request .= qq{
        LEFT JOIN categories_branches ON categories.categorycode = categories_branches.categorycode
    } if $branch_limit;
    if($action) {
        $request .= " $action ";
        $request .= " AND (branchcode = ? OR branchcode IS NULL) GROUP BY description" if $branch_limit;
    } else {
        $request .= " WHERE branchcode = ? OR branchcode IS NULL GROUP BY description" if $branch_limit;
    }
    $request .= " ORDER BY categorycode";

    my $sth = $dbh->prepare($request);
    $sth->execute(
        $action ? $category_type : (),
        $branch_limit ? $branch_limit : ()
    );

    my %labels;
    my @codes;

    while ( my $data = $sth->fetchrow_hashref ) {
        push @codes, $data->{'categorycode'};
        $labels{ $data->{'categorycode'} } = $data->{'description'};
    }
    $sth->finish;
    return ( \@codes, \%labels );
}

=head2 GetBorrowercategory

  $hashref = &GetBorrowercategory($categorycode);

Given the borrower's category code, the function returns the corresponding
data hashref for a comprehensive information display.

=cut

sub GetBorrowercategory {
    my ($catcode) = @_;
    my $dbh       = C4::Context->dbh;
    if ($catcode){
        my $sth       =
        $dbh->prepare(
    "SELECT description,dateofbirthrequired,upperagelimit,category_type 
    FROM categories 
    WHERE categorycode = ?"
        );
        $sth->execute($catcode);
        my $data =
        $sth->fetchrow_hashref;
        return $data;
    } 
    return;  
}    # sub getborrowercategory


=head2 GetBorrowerCategorycode

    $categorycode = &GetBorrowerCategoryCode( $borrowernumber );

Given the borrowernumber, the function returns the corresponding categorycode
=cut

sub GetBorrowerCategorycode {
    my ( $borrowernumber ) = @_;
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare( qq{
        SELECT categorycode
        FROM borrowers
        WHERE borrowernumber = ?
    } );
    $sth->execute( $borrowernumber );
    return $sth->fetchrow;
}

=head2 GetBorrowercategoryList

  $arrayref_hashref = &GetBorrowercategoryList;
If no category code provided, the function returns all the categories.

=cut

sub GetBorrowercategoryList {
    my $no_branch_limit = @_ ? shift : 0;
    my $branch_limit = $no_branch_limit
        ? 0
        : C4::Context->userenv ? C4::Context->userenv->{"branch"} : "";
    my $dbh       = C4::Context->dbh;
    my $query = "SELECT categories.* FROM categories";
    $query .= qq{
        LEFT JOIN categories_branches ON categories.categorycode = categories_branches.categorycode
        WHERE branchcode = ? OR branchcode IS NULL GROUP BY description
    } if $branch_limit;
    $query .= " ORDER BY description";
    my $sth = $dbh->prepare( $query );
    $sth->execute( $branch_limit ? $branch_limit : () );
    my $data = $sth->fetchall_arrayref( {} );
    $sth->finish;
    return $data;
}    # sub getborrowercategory

=head2 ethnicitycategories

  ($codes_arrayref, $labels_hashref) = &ethnicitycategories();

Looks up the different ethnic types in the database. Returns two
elements: a reference-to-array, which lists the ethnicity codes, and a
reference-to-hash, which maps the ethnicity codes to ethnicity
descriptions.

=cut

#'

sub ethnicitycategories {
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("Select code,name from ethnicity order by name");
    $sth->execute;
    my %labels;
    my @codes;
    while ( my $data = $sth->fetchrow_hashref ) {
        push @codes, $data->{'code'};
        $labels{ $data->{'code'} } = $data->{'name'};
    }
    return ( \@codes, \%labels );
}

=head2 fixEthnicity

  $ethn_name = &fixEthnicity($ethn_code);

Takes an ethnicity code (e.g., "european" or "pi") and returns the
corresponding descriptive name from the C<ethnicity> table in the
Koha database ("European" or "Pacific Islander").

=cut

#'

sub fixEthnicity {
    my $ethnicity = shift;
    return unless $ethnicity;
    my $dbh       = C4::Context->dbh;
    my $sth       = $dbh->prepare("Select name from ethnicity where code = ?");
    $sth->execute($ethnicity);
    my $data = $sth->fetchrow_hashref;
    return $data->{'name'};
}    # sub fixEthnicity

=head2 GetAge

  $dateofbirth,$date = &GetAge($date);

this function return the borrowers age with the value of dateofbirth

=cut

#'
sub GetAge{
    my ( $date, $date_ref ) = @_;

    if ( not defined $date_ref ) {
        $date_ref = sprintf( '%04d-%02d-%02d', Today() );
    }

    my ( $year1, $month1, $day1 ) = split /-/, $date;
    my ( $year2, $month2, $day2 ) = split /-/, $date_ref;

    my $age = $year2 - $year1;
    if ( $month1 . $day1 > $month2 . $day2 ) {
        $age--;
    }

    return $age;
}    # sub get_age

=head2 get_institutions

  $insitutions = get_institutions();

Just returns a list of all the borrowers of type I, borrownumber and name

=cut

#'
sub get_institutions {
    my $dbh = C4::Context->dbh();
    my $sth =
      $dbh->prepare(
"SELECT borrowernumber,surname FROM borrowers WHERE categorycode=? ORDER BY surname"
      );
    $sth->execute('I');
    my %orgs;
    while ( my $data = $sth->fetchrow_hashref() ) {
        $orgs{ $data->{'borrowernumber'} } = $data;
    }
    return ( \%orgs );

}    # sub get_institutions

=head2 add_member_orgs

  add_member_orgs($borrowernumber,$borrowernumbers);

Takes a borrowernumber and a list of other borrowernumbers and inserts them into the borrowers_to_borrowers table

=cut

#'
sub add_member_orgs {
    my ( $borrowernumber, $otherborrowers ) = @_;
    my $dbh   = C4::Context->dbh();
    my $query =
      "INSERT INTO borrowers_to_borrowers (borrower1,borrower2) VALUES (?,?)";
    my $sth = $dbh->prepare($query);
    foreach my $otherborrowernumber (@$otherborrowers) {
        $sth->execute( $borrowernumber, $otherborrowernumber );
    }

}    # sub add_member_orgs

=head2 GetCities

  $cityarrayref = GetCities();

  Returns an array_ref of the entries in the cities table
  If there are entries in the table an empty row is returned
  This is currently only used to populate a popup in memberentry

=cut

sub GetCities {

    my $dbh   = C4::Context->dbh;
    my $city_arr = $dbh->selectall_arrayref(
        q|SELECT cityid,city_zipcode,city_name,city_state,city_country FROM cities ORDER BY city_name|,
        { Slice => {} });
    if ( @{$city_arr} ) {
        unshift @{$city_arr}, {
            city_zipcode => q{},
            city_name    => q{},
            cityid       => q{},
            city_state   => q{},
            city_country => q{},
        };
    }

    return  $city_arr;
}

=head2 GetSortDetails (OUEST-PROVENCE)

  ($lib) = &GetSortDetails($category,$sortvalue);

Returns the authorized value  details
C<&$lib>return value of authorized value details
C<&$sortvalue>this is the value of authorized value 
C<&$category>this is the value of authorized value category

=cut

sub GetSortDetails {
    my ( $category, $sortvalue ) = @_;
    my $dbh   = C4::Context->dbh;
    my $query = qq|SELECT lib 
        FROM authorised_values 
        WHERE category=?
        AND authorised_value=? |;
    my $sth = $dbh->prepare($query);
    $sth->execute( $category, $sortvalue );
    my $lib = $sth->fetchrow;
    return ($lib) if ($lib);
    return ($sortvalue) unless ($lib);
}

=head2 MoveMemberToDeleted

  $result = &MoveMemberToDeleted($borrowernumber);

Copy the record from borrowers to deletedborrowers table.

=cut

# FIXME: should do it in one SQL statement w/ subquery
# Otherwise, we should return the @data on success

sub MoveMemberToDeleted {
    my ($member) = shift or return;
    my $dbh = C4::Context->dbh;
    my $query = qq|SELECT * 
          FROM borrowers 
          WHERE borrowernumber=?|;
    my $sth = $dbh->prepare($query);
    $sth->execute($member);
    my @data = $sth->fetchrow_array;
    (@data) or return;  # if we got a bad borrowernumber, there's nothing to insert
    $sth =
      $dbh->prepare( "INSERT INTO deletedborrowers VALUES ("
          . ( "?," x ( scalar(@data) - 1 ) )
          . "?)" );
    $sth->execute(@data);
}

=head2 DelMember

    DelMember($borrowernumber);

This function remove directly a borrower whitout writing it on deleteborrower.
+ Deletes reserves for the borrower

=cut

sub DelMember {
    my $dbh            = C4::Context->dbh;
    my $borrowernumber = shift;
    #warn "in delmember with $borrowernumber";
    return unless $borrowernumber;    # borrowernumber is mandatory.

    my $query = qq|DELETE 
          FROM  reserves 
          WHERE borrowernumber=?|;
    my $sth = $dbh->prepare($query);
    $sth->execute($borrowernumber);
    $query = "
       DELETE
       FROM borrowers
       WHERE borrowernumber = ?
   ";
    $sth = $dbh->prepare($query);
    $sth->execute($borrowernumber);
    logaction("MEMBERS", "DELETE", $borrowernumber, "") if C4::Context->preference("BorrowersLog");
    return $sth->rows;
}

=head2 ExtendMemberSubscriptionTo (OUEST-PROVENCE)

    $date = ExtendMemberSubscriptionTo($borrowerid, $date);

Extending the subscription to a given date or to the expiry date calculated on ISO date.
Returns ISO date.

=cut

sub ExtendMemberSubscriptionTo {
    my ( $borrowerid,$date) = @_;
    my $dbh = C4::Context->dbh;
    my $borrower = GetMember('borrowernumber'=>$borrowerid);
    unless ($date){
      $date = (C4::Context->preference('BorrowerRenewalPeriodBase') eq 'dateexpiry') ?
                                        C4::Dates->new($borrower->{'dateexpiry'}, 'iso')->output("iso") :
                                        C4::Dates->new()->output("iso");
      $date = GetExpiryDate( $borrower->{'categorycode'}, $date );
    }
    my $sth = $dbh->do(<<EOF);
UPDATE borrowers 
SET  dateexpiry='$date' 
WHERE borrowernumber='$borrowerid'
EOF
    # add enrolmentfee if needed
    $sth = $dbh->prepare("SELECT enrolmentfee FROM categories WHERE categorycode=?");
    $sth->execute($borrower->{'categorycode'});
    my ($enrolmentfee) = $sth->fetchrow;
    if ($enrolmentfee && $enrolmentfee > 0) {
        # insert fee in patron debts
        manualinvoice($borrower->{'borrowernumber'}, '', '', 'A', $enrolmentfee);
    }
     logaction("MEMBERS", "RENEW", $borrower->{'borrowernumber'}, "Membership renewed")if C4::Context->preference("BorrowersLog");
    return $date if ($sth);
    return 0;
}

=head2 GetRoadTypes (OUEST-PROVENCE)

  ($idroadtypearrayref, $roadttype_hashref) = &GetRoadTypes();

Looks up the different road type . Returns two
elements: a reference-to-array, which lists the id_roadtype
codes, and a reference-to-hash, which maps the road type of the road .

=cut

sub GetRoadTypes {
    my $dbh   = C4::Context->dbh;
    my $query = qq|
SELECT roadtypeid,road_type 
FROM roadtype 
ORDER BY road_type|;
    my $sth = $dbh->prepare($query);
    $sth->execute();
    my %roadtype;
    my @id;

    #    insert empty value to create a empty choice in cgi popup

    while ( my $data = $sth->fetchrow_hashref ) {

        push @id, $data->{'roadtypeid'};
        $roadtype{ $data->{'roadtypeid'} } = $data->{'road_type'};
    }

#test to know if the table contain some records if no the function return nothing
    my $id = @id;
    if ( $id eq 0 ) {
        return ();
    }
    else {
        unshift( @id, "" );
        return ( \@id, \%roadtype );
    }
}



=head2 GetTitles (OUEST-PROVENCE)

  ($borrowertitle)= &GetTitles();

Looks up the different title . Returns array  with all borrowers title

=cut

sub GetTitles {
    my @borrowerTitle = split (/,|\|/,C4::Context->preference('BorrowersTitles'));
    unshift( @borrowerTitle, "" );
    my $count=@borrowerTitle;
    if ($count == 1){
        return ();
    }
    else {
        return ( \@borrowerTitle);
    }
}

=head2 GetPatronImage

    my ($imagedata, $dberror) = GetPatronImage($cardnumber);

Returns the mimetype and binary image data of the image for the patron with the supplied cardnumber.

=cut

sub GetPatronImage {
    my ($cardnumber) = @_;
    warn "Cardnumber passed to GetPatronImage is $cardnumber" if $debug;
    my $dbh = C4::Context->dbh;
    my $query = 'SELECT mimetype, imagefile FROM patronimage WHERE cardnumber = ?';
    my $sth = $dbh->prepare($query);
    $sth->execute($cardnumber);
    my $imagedata = $sth->fetchrow_hashref;
    warn "Database error!" if $sth->errstr;
    return $imagedata, $sth->errstr;
}

=head2 PutPatronImage

    PutPatronImage($cardnumber, $mimetype, $imgfile);

Stores patron binary image data and mimetype in database.
NOTE: This function is good for updating images as well as inserting new images in the database.

=cut

sub PutPatronImage {
    my ($cardnumber, $mimetype, $imgfile) = @_;
    warn "Parameters passed in: Cardnumber=$cardnumber, Mimetype=$mimetype, " . ($imgfile ? "Imagefile" : "No Imagefile") if $debug;
    my $dbh = C4::Context->dbh;
    my $query = "INSERT INTO patronimage (cardnumber, mimetype, imagefile) VALUES (?,?,?) ON DUPLICATE KEY UPDATE imagefile = ?;";
    my $sth = $dbh->prepare($query);
    $sth->execute($cardnumber,$mimetype,$imgfile,$imgfile);
    warn "Error returned inserting $cardnumber.$mimetype." if $sth->errstr;
    return $sth->errstr;
}

=head2 RmPatronImage

    my ($dberror) = RmPatronImage($cardnumber);

Removes the image for the patron with the supplied cardnumber.

=cut

sub RmPatronImage {
    my ($cardnumber) = @_;
    warn "Cardnumber passed to GetPatronImage is $cardnumber" if $debug;
    my $dbh = C4::Context->dbh;
    my $query = "DELETE FROM patronimage WHERE cardnumber = ?;";
    my $sth = $dbh->prepare($query);
    $sth->execute($cardnumber);
    my $dberror = $sth->errstr;
    warn "Database error!" if $sth->errstr;
    return $dberror;
}

=head2 GetHideLostItemsPreference

  $hidelostitemspref = &GetHideLostItemsPreference($borrowernumber);

Returns the HideLostItems preference for the patron category of the supplied borrowernumber
C<&$hidelostitemspref>return value of function, 0 or 1

=cut

sub GetHideLostItemsPreference {
    my ($borrowernumber) = @_;
    my $dbh = C4::Context->dbh;
    my $query = "SELECT hidelostitems FROM borrowers,categories WHERE borrowers.categorycode = categories.categorycode AND borrowernumber = ?";
    my $sth = $dbh->prepare($query);
    $sth->execute($borrowernumber);
    my $hidelostitems = $sth->fetchrow;    
    return $hidelostitems;    
}

=head2 GetRoadTypeDetails (OUEST-PROVENCE)

  ($roadtype) = &GetRoadTypeDetails($roadtypeid);

Returns the description of roadtype
C<&$roadtype>return description of road type
C<&$roadtypeid>this is the value of roadtype s

=cut

sub GetRoadTypeDetails {
    my ($roadtypeid) = @_;
    my $dbh          = C4::Context->dbh;
    my $query        = qq|
SELECT road_type 
FROM roadtype 
WHERE roadtypeid=?|;
    my $sth = $dbh->prepare($query);
    $sth->execute($roadtypeid);
    my $roadtype = $sth->fetchrow;
    return ($roadtype);
}

=head2 GetBorrowersToExpunge

  $borrowers = &GetBorrowersToExpunge(
      not_borrowered_since => $not_borrowered_since,
      expired_before       => $expired_before,
      category_code        => $category_code,
      branchcode           => $branchcode
  );

  This function get all borrowers based on the given criteria.

=cut

sub GetBorrowersToExpunge {
    my $params = shift;

    my $filterdate     = $params->{'not_borrowered_since'};
    my $filterexpiry   = $params->{'expired_before'};
    my $filtercategory = $params->{'category_code'};
    my $filterbranch   = $params->{'branchcode'} ||
                        ((C4::Context->preference('IndependentBranches')
                             && C4::Context->userenv 
                             && C4::Context->userenv->{flags} % 2 !=1 
                             && C4::Context->userenv->{branch})
                         ? C4::Context->userenv->{branch}
                         : "");  

    my $dbh   = C4::Context->dbh;
    my $query = "
        SELECT borrowers.borrowernumber,
               MAX(old_issues.timestamp) AS latestissue,
               MAX(issues.timestamp) AS currentissue
        FROM   borrowers
        JOIN   categories USING (categorycode)
        LEFT JOIN old_issues USING (borrowernumber)
        LEFT JOIN issues USING (borrowernumber) 
        WHERE  category_type <> 'S'
        AND borrowernumber NOT IN (SELECT guarantorid FROM borrowers WHERE guarantorid IS NOT NULL AND guarantorid <> 0)
   ";
    my @query_params;
    if ( $filterbranch && $filterbranch ne "" ) {
        $query.= " AND borrowers.branchcode = ? ";
        push( @query_params, $filterbranch );
    }
    if ( $filterexpiry ) {
        $query .= " AND dateexpiry < ? ";
        push( @query_params, $filterexpiry );
    }
    if ( $filtercategory ) {
        $query .= " AND categorycode = ? ";
        push( @query_params, $filtercategory );
    }
    $query.=" GROUP BY borrowers.borrowernumber HAVING currentissue IS NULL ";
    if ( $filterdate ) {
        $query.=" AND ( latestissue < ? OR latestissue IS NULL ) ";
        push @query_params,$filterdate;
    }
    warn $query if $debug;

    my $sth = $dbh->prepare($query);
    if (scalar(@query_params)>0){  
        $sth->execute(@query_params);
    } 
    else {
        $sth->execute;
    }      
    
    my @results;
    while ( my $data = $sth->fetchrow_hashref ) {
        push @results, $data;
    }
    return \@results;
}

=head2 GetBorrowersWhoHaveNeverBorrowed

  $results = &GetBorrowersWhoHaveNeverBorrowed

This function get all borrowers who have never borrowed.

I<$result> is a ref to an array which all elements are a hasref.

=cut

sub GetBorrowersWhoHaveNeverBorrowed {
    my $filterbranch = shift || 
                        ((C4::Context->preference('IndependentBranches')
                             && C4::Context->userenv 
                             && C4::Context->userenv->{flags} % 2 !=1 
                             && C4::Context->userenv->{branch})
                         ? C4::Context->userenv->{branch}
                         : "");  
    my $dbh   = C4::Context->dbh;
    my $query = "
        SELECT borrowers.borrowernumber,max(timestamp) as latestissue
        FROM   borrowers
          LEFT JOIN issues ON borrowers.borrowernumber = issues.borrowernumber
        WHERE issues.borrowernumber IS NULL
   ";
    my @query_params;
    if ($filterbranch && $filterbranch ne ""){ 
        $query.=" AND borrowers.branchcode= ?";
        push @query_params,$filterbranch;
    }
    warn $query if $debug;
  
    my $sth = $dbh->prepare($query);
    if (scalar(@query_params)>0){  
        $sth->execute(@query_params);
    } 
    else {
        $sth->execute;
    }      
    
    my @results;
    while ( my $data = $sth->fetchrow_hashref ) {
        push @results, $data;
    }
    return \@results;
}

=head2 GetBorrowersWithIssuesHistoryOlderThan

  $results = &GetBorrowersWithIssuesHistoryOlderThan($date)

this function get all borrowers who has an issue history older than I<$date> given on input arg.

I<$result> is a ref to an array which all elements are a hashref.
This hashref is containt the number of time this borrowers has borrowed before I<$date> and the borrowernumber.

=cut

sub GetBorrowersWithIssuesHistoryOlderThan {
    my $dbh  = C4::Context->dbh;
    my $date = shift ||POSIX::strftime("%Y-%m-%d",localtime());
    my $filterbranch = shift || 
                        ((C4::Context->preference('IndependentBranches')
                             && C4::Context->userenv 
                             && C4::Context->userenv->{flags} % 2 !=1 
                             && C4::Context->userenv->{branch})
                         ? C4::Context->userenv->{branch}
                         : "");  
    my $query = "
       SELECT count(borrowernumber) as n,borrowernumber
       FROM old_issues
       WHERE returndate < ?
         AND borrowernumber IS NOT NULL 
    "; 
    my @query_params;
    push @query_params, $date;
    if ($filterbranch){
        $query.="   AND branchcode = ?";
        push @query_params, $filterbranch;
    }    
    $query.=" GROUP BY borrowernumber ";
    warn $query if $debug;
    my $sth = $dbh->prepare($query);
    $sth->execute(@query_params);
    my @results;

    while ( my $data = $sth->fetchrow_hashref ) {
        push @results, $data;
    }
    return \@results;
}

=head2 GetBorrowersNamesAndLatestIssue

  $results = &GetBorrowersNamesAndLatestIssueList(@borrowernumbers)

this function get borrowers Names and surnames and Issue information.

I<@borrowernumbers> is an array which all elements are borrowernumbers.
This hashref is containt the number of time this borrowers has borrowed before I<$date> and the borrowernumber.

=cut

sub GetBorrowersNamesAndLatestIssue {
    my $dbh  = C4::Context->dbh;
    my @borrowernumbers=@_;  
    my $query = "
       SELECT surname,lastname, phone, email,max(timestamp)
       FROM borrowers 
         LEFT JOIN issues ON borrowers.borrowernumber=issues.borrowernumber
       GROUP BY borrowernumber
   ";
    my $sth = $dbh->prepare($query);
    $sth->execute;
    my $results = $sth->fetchall_arrayref({});
    return $results;
}

=head2 DebarMember

my $success = DebarMember( $borrowernumber, $todate );

marks a Member as debarred, and therefore unable to checkout any more
items.

return :
true on success, false on failure

=cut

sub DebarMember {
    my $borrowernumber = shift;
    my $todate         = shift;

    return unless defined $borrowernumber;
    return unless $borrowernumber =~ /^\d+$/;

    return ModMember(
        borrowernumber => $borrowernumber,
        debarred       => $todate
    );

}

=head2 ModPrivacy

=over 4

my $success = ModPrivacy( $borrowernumber, $privacy );

Update the privacy of a patron.

return :
true on success, false on failure

=back

=cut

sub ModPrivacy {
    my $borrowernumber = shift;
    my $privacy = shift;
    return unless defined $borrowernumber;
    return unless $borrowernumber =~ /^\d+$/;

    return ModMember( borrowernumber => $borrowernumber,
                      privacy        => $privacy );
}

=head2 AddMessage

  AddMessage( $borrowernumber, $message_type, $message, $branchcode );

Adds a message to the messages table for the given borrower.

Returns:
  True on success
  False on failure

=cut

sub AddMessage {
    my ( $borrowernumber, $message_type, $message, $branchcode ) = @_;

    my $dbh  = C4::Context->dbh;

    if ( ! ( $borrowernumber && $message_type && $message && $branchcode ) ) {
      return;
    }

    my $query = "INSERT INTO messages ( borrowernumber, branchcode, message_type, message ) VALUES ( ?, ?, ?, ? )";
    my $sth = $dbh->prepare($query);
    $sth->execute( $borrowernumber, $branchcode, $message_type, $message );
    logaction("MEMBERS", "ADDCIRCMESSAGE", $borrowernumber, $message) if C4::Context->preference("BorrowersLog");
    return 1;
}

=head2 GetMessages

  GetMessages( $borrowernumber, $type );

$type is message type, B for borrower, or L for Librarian.
Empty type returns all messages of any type.

Returns all messages for the given borrowernumber

=cut

sub GetMessages {
    my ( $borrowernumber, $type, $branchcode ) = @_;

    if ( ! $type ) {
      $type = '%';
    }

    my $dbh  = C4::Context->dbh;

    my $query = "SELECT
                  branches.branchname,
                  messages.*,
                  message_date,
                  messages.branchcode LIKE '$branchcode' AS can_delete
                  FROM messages, branches
                  WHERE borrowernumber = ?
                  AND message_type LIKE ?
                  AND messages.branchcode = branches.branchcode
                  ORDER BY message_date DESC";
    my $sth = $dbh->prepare($query);
    $sth->execute( $borrowernumber, $type ) ;
    my @results;

    while ( my $data = $sth->fetchrow_hashref ) {
        my $d = C4::Dates->new( $data->{message_date}, 'iso' );
        $data->{message_date_formatted} = $d->output;
        push @results, $data;
    }
    return \@results;

}

=head2 GetMessages

  GetMessagesCount( $borrowernumber, $type );

$type is message type, B for borrower, or L for Librarian.
Empty type returns all messages of any type.

Returns the number of messages for the given borrowernumber

=cut

sub GetMessagesCount {
    my ( $borrowernumber, $type, $branchcode ) = @_;

    if ( ! $type ) {
      $type = '%';
    }

    my $dbh  = C4::Context->dbh;

    my $query = "SELECT COUNT(*) as MsgCount FROM messages WHERE borrowernumber = ? AND message_type LIKE ?";
    my $sth = $dbh->prepare($query);
    $sth->execute( $borrowernumber, $type ) ;
    my @results;

    my $data = $sth->fetchrow_hashref;
    my $count = $data->{'MsgCount'};

    return $count;
}



=head2 DeleteMessage

  DeleteMessage( $message_id );

=cut

sub DeleteMessage {
    my ( $message_id ) = @_;

    my $dbh = C4::Context->dbh;
    my $query = "SELECT * FROM messages WHERE message_id = ?";
    my $sth = $dbh->prepare($query);
    $sth->execute( $message_id );
    my $message = $sth->fetchrow_hashref();

    $query = "DELETE FROM messages WHERE message_id = ?";
    $sth = $dbh->prepare($query);
    $sth->execute( $message_id );
    logaction("MEMBERS", "DELCIRCMESSAGE", $message->{'borrowernumber'}, $message->{'message'}) if C4::Context->preference("BorrowersLog");
}

=head2 IssueSlip

  IssueSlip($branchcode, $borrowernumber, $quickslip)

  Returns letter hash ( see C4::Letters::GetPreparedLetter )

  $quickslip is boolean, to indicate whether we want a quick slip

=cut

sub IssueSlip {
    my ($branch, $borrowernumber, $quickslip) = @_;

#   return unless ( C4::Context->boolean_preference('printcirculationslips') );

    my $now       = POSIX::strftime("%Y-%m-%d", localtime);

    my $issueslist = GetPendingIssues($borrowernumber);
    foreach my $it (@$issueslist){
        if ((substr $it->{'issuedate'}, 0, 10) eq $now || (substr $it->{'lastreneweddate'}, 0, 10) eq $now) {
            $it->{'now'} = 1;
        }
        elsif ((substr $it->{'date_due'}, 0, 10) le $now) {
            $it->{'overdue'} = 1;
        }
        my $dt = dt_from_string( $it->{'date_due'} );
        $it->{'date_due'} = output_pref( $dt );;
    }
    my @issues = sort { $b->{'timestamp'} <=> $a->{'timestamp'} } @$issueslist;

    my ($letter_code, %repeat);
    if ( $quickslip ) {
        $letter_code = 'ISSUEQSLIP';
        %repeat =  (
            'checkedout' => [ map {
                'biblio' => $_,
                'items'  => $_,
                'issues' => $_,
            }, grep { $_->{'now'} } @issues ],
        );
    }
    else {
        $letter_code = 'ISSUESLIP';
        %repeat =  (
            'checkedout' => [ map {
                'biblio' => $_,
                'items'  => $_,
                'issues' => $_,
            }, grep { !$_->{'overdue'} } @issues ],

            'overdue' => [ map {
                'biblio' => $_,
                'items'  => $_,
                'issues' => $_,
            }, grep { $_->{'overdue'} } @issues ],

            'news' => [ map {
                $_->{'timestamp'} = $_->{'newdate'};
                { opac_news => $_ }
            } @{ GetNewsToDisplay("slip") } ],
        );
    }

    return  C4::Letters::GetPreparedLetter (
        module => 'circulation',
        letter_code => $letter_code,
        branchcode => $branch,
        tables => {
            'branches'    => $branch,
            'borrowers'   => $borrowernumber,
        },
        repeat => \%repeat,
    );
}

=head2 GetBorrowersWithEmail

    ([$borrnum,$userid], ...) = GetBorrowersWithEmail('me@example.com');

This gets a list of users and their basic details from their email address.
As it's possible for multiple user to have the same email address, it provides
you with all of them. If there is no userid for the user, there will be an
C<undef> there. An empty list will be returned if there are no matches.

=cut

sub GetBorrowersWithEmail {
    my $email = shift;

    my $dbh = C4::Context->dbh;

    my $query = "SELECT borrowernumber, userid FROM borrowers WHERE email=?";
    my $sth=$dbh->prepare($query);
    $sth->execute($email);
    my @result = ();
    while (my $ref = $sth->fetch) {
        push @result, $ref;
    }
    die "Failure searching for borrowers by email address: $sth->errstr" if $sth->err;
    return @result;
}

sub AddMember_Opac {
    my ( %borrower ) = @_;

    $borrower{'categorycode'} = C4::Context->preference('PatronSelfRegistrationDefaultCategory');

    my $sr = new String::Random;
    $sr->{'A'} = [ 'A'..'Z', 'a'..'z' ];
    my $password = $sr->randpattern("AAAAAAAAAA");
    $borrower{'password'} = $password;

    $borrower{'cardnumber'} = fixup_cardnumber();

    my $borrowernumber = AddMember(%borrower);

    return ( $borrowernumber, $password );
}

END { }    # module clean-up code here (global destructor)

1;

__END__

=head1 AUTHOR

Koha Team

=cut
