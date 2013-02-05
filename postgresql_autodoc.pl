#!/usr/bin/perl -- # -*- Perl -*-w
# $Header: /cvsroot/pgsqlautodoc/autodoc/postgresql_autodoc.pl,v 1.37 2002/09/03 16:24:05 rtaylor02 Exp $
#  Imported 1.22 2002/02/08 17:09:48 into sourceforge

# Postgres Auto-Doc Version 1.00

# License
# -------
# Copyright (c) 2001, Rod Taylor
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1.   Redistributions of source code must retain the above copyright
#      notice, this list of conditions and the following disclaimer.
#
# 2.   Redistributions in binary form must reproduce the above
#      copyright notice, this list of conditions and the following
#      disclaimer in the documentation and/or other materials provided
#      with the distribution.
#
# 3.   Neither the name of the InQuent Technologies Inc. nor the names
#      of its contributors may be used to endorse or promote products
#      derived from this software without specific prior written
#      permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE FREEBSD
# PROJECT OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT 
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# About Project
# -------------
# Various details about the project and related items can be found at 
# the website
#
# http://www.rbt.ca/autodoc/

use DBI;
use strict;

# Allows file locking
use Fcntl;

use Data::Dumper;

#
# Just Code below here -- nothing to see unless your feeling masochistic.
#
my $dbuser = $ENV{'PGUSER'};
$dbuser ||= $ENV{'USER'};

my $database = $ENV{'PGDATABASE'};
$database ||= $dbuser;

my $dbhost = $ENV{'PGHOST'};
$dbhost ||= "";

my $dbport = $ENV{'PGPORT'};
$dbport ||= "";

my $dbpass             = "";
my $index_outputfile   = "$database.html";
my $docbook_outputfile = "$database.xml";
my $uml_outputfile     = "$database.dia";
my $dot_outputfile     = "$database.dot";

my $do_index   = 1;
my $do_uml     = 1;
my $do_docbook = 1;
my $do_dot     = 1;

my $dbisset   = 0;
my $fileisset = 0;

my $basename = $0;
$basename =~ s|.*/([^/]+)$|$1|;

for ( my $i = 0 ; $i <= $#ARGV ; $i++ ) {
  ARGPARSE: for ( $ARGV[$i] ) {
        /^-d$/ && do {
            $database = $ARGV[ ++$i ];
            $dbisset  = 1;
            if ( !$fileisset ) {
                $uml_outputfile     = $database . '.dia';
                $dot_outputfile     = $database . '.dot';
                $index_outputfile   = $database . '.html';
                $docbook_outputfile = $database . '.sgml';
            }
            last;
        };

        /^-[uU]$/ && do {
            $dbuser = $ARGV[ ++$i ];
            if ( !$dbisset ) {
                $database = $dbuser;
                if ( !$fileisset ) {
                    $uml_outputfile     = $database . '.dia';
                    $dot_outputfile     = $database . '.dot';
                    $index_outputfile   = $database . '.html';
                    $docbook_outputfile = $database . '.sgml';
                }
            }
            last;
        };

        /^-h$/ && do { $dbhost = $ARGV[ ++$i ]; last; };
        /^-p$/ && do { $dbport = $ARGV[ ++$i ]; last; };

        /^--password=/ && do {
            $dbpass = $ARGV[$i];
            $dbpass =~ s/^--password=//g;
            last;
        };

        /^-f$/ && do {
            $uml_outputfile = $ARGV[ ++$i ];
            $fileisset      = 1;
            last;
        };

        /^-F$/ && do {
            $index_outputfile = $ARGV[ ++$i ];
            $fileisset        = 1;
            last;
        };

        /^--no-index$/   && do { $do_index   = 0; last; };
        /^--no-uml$/     && do { $do_uml     = 0; last; };
        /^--no-docbook$/ && do { $do_docbook = 0; last; };
        /^--no-dot$/     && do { $do_dot     = 0; last; };

        /^-\?$/    && do { usage(); last; };
        /^--help$/ && do { usage(); last; };

    }
}

if ( $#ARGV <= 0 ) {
    print <<Msg
No arguments set.  Use '$basename --help' for help

Connecting to database '$database' as user '$dbuser'
Msg
;
}

my $dsn = "dbi:Pg:dbname=$database";
$dsn .= ";host=$dbhost" if ( "$dbhost" ne "" );
$dsn .= ";port=$dbport" if ( "$dbport" ne "" );

# Database Connection
# -------------------
my $dbh = DBI->connect( $dsn, $dbuser, $dbpass );

# $dbh->{'AutoCommit'} = 0;

END {
    $dbh->disconnect() if $dbh;
}

## Fetch the version of PostgreSQL
my $sql_GetVersion = qq{
  SELECT cast(substr(version(), 12, 1) as integer) * 10000
         + cast(substr(version(), 14, 1) as integer) * 100
         as version;
};

my $sth_GetVersion = $dbh->prepare($sql_GetVersion);
$sth_GetVersion->execute();
my $version   = $sth_GetVersion->fetchrow_hashref;
my $pgversion = $version->{'version'};

my $system_schema;
if ( $pgversion >= 70300 ) {
    $system_schema = 'pg_catalog';
}
else {
    $system_schema = 'public';
}

# Queries which differ depending on version
my $sql_Database;
my $sql_Tables;
my $sql_Columns;
my $sql_Constraint;
my $sql_Function;
my $sql_FunctionArg;
my $sql_Foreign_Keys;
my $sql_Foreign_Key_Arg;
my $sql_Schema;

## Fetch for tables and classes
if ( $pgversion >= 70300 ) {
    $sql_Tables = qq{
    SELECT pg_catalog.quote_ident(nspname) as namespace
         , pg_catalog.quote_ident(relname) as tablename
         , pg_catalog.pg_get_userbyid(relowner) AS tableowner
         , relhasindex as hasindexes
         , relhasrules as hasrules
         , reltriggers as hastriggers
         , pg_class.oid
         , pg_catalog.obj_description(pg_class.oid, 'pg_class') as table_description
         , relacl
      FROM pg_catalog.pg_class
      JOIN pg_catalog.pg_namespace ON (relnamespace = pg_namespace.oid)
     WHERE (  relkind = 'r'::"char"
           OR relkind = 's'::"char"
           )
       AND nspname != '$system_schema';
    };

    # - uses pg_class.oid
    $sql_Columns = qq{
    SELECT pg_catalog.quote_ident(attname) as column_name
         , attlen as column_length
         , CASE
           WHEN pg_type.typname = 'int4'
                AND EXISTS (SELECT TRUE
                              FROM pg_catalog.pg_depend
                              JOIN pg_catalog.pg_class ON (pg_class.oid = objid)
                             WHERE refobjsubid = attnum
                               AND refobjid = attrelid
                               AND relkind = 'S') THEN
             'serial'
           WHEN pg_type.typname = 'int8'
                AND EXISTS (SELECT TRUE
                              FROM pg_catalog.pg_depend
                              JOIN pg_catalog.pg_class ON (pg_class.oid = objid)
                             WHERE refobjsubid = attnum
                               AND refobjid = attrelid
                               AND relkind = 'S') THEN
             'bigserial'
           ELSE
             pg_catalog.format_type(atttypid, atttypmod)
           END as column_type
         , CASE
           WHEN attnotnull THEN
             cast('NOT NULL' as text)
           ELSE
             cast('' as text)
           END as column_null
         , CASE
           WHEN pg_type.typname IN ('int4', 'int8')
                AND EXISTS (SELECT TRUE
                              FROM pg_catalog.pg_depend
                              JOIN pg_catalog.pg_class ON (pg_class.oid = objid)
                             WHERE refobjsubid = attnum
                               AND refobjid = attrelid
                               AND relkind = 'S') THEN
             NULL
           ELSE
             adsrc
           END as column_default
         , pg_catalog.col_description(attrelid, attnum) as column_description
         , attnum
      FROM pg_catalog.pg_attribute 
                 JOIN pg_catalog.pg_type ON (pg_type.oid = atttypid) 
      LEFT OUTER JOIN pg_catalog.pg_attrdef ON (   attrelid = adrelid 
                                               AND attnum = adnum)
     WHERE attnum > 0
       AND attisdropped IS FALSE
       AND attrelid = ?;
    };

}
elsif ( $pgversion >= 70200 ) {
    $sql_Tables = qq{
    SELECT quote_ident('public') as namespace
         , quote_ident(relname) as tablename
         , pg_get_userbyid(relowner) AS tableowner
         , relhasindex as hasindexes
         , relhasrules as hasrules
         , reltriggers as hastriggers
         , pg_class.oid
         , obj_description(pg_class.oid, 'pg_class') as table_description
         , relacl
      FROM pg_class
     WHERE (  relkind = 'r'::"char"
           OR relkind = 's'::"char"
           )
       AND relname NOT LIKE 'pg_%';
    };

    # - uses pg_class.oid
    $sql_Columns = qq{
    SELECT quote_ident(attname) as column_name
         , attlen as column_length
         , CASE
           WHEN pg_type.typname = 'int4'
                AND adsrc LIKE 'nextval(%' THEN
             'serial'
           WHEN pg_type.typname = 'int8'
                AND adsrc LIKE 'nextval(%' THEN
             'bigserial'
           ELSE
             format_type(atttypid, atttypmod)
           END as column_type
         , CASE
           WHEN attnotnull IS TRUE THEN
             'NOT NULL'::text
           ELSE
             ''::text
           END as column_null
         , CASE
           WHEN pg_type.typname in ('int4', 'int8')
                AND adsrc LIKE 'nextval(%' THEN
             NULL
           ELSE
             adsrc
           END as column_default
         , col_description(attrelid, attnum) as column_description
         , attnum
      FROM pg_attribute 
                 JOIN pg_type ON (pg_type.oid = pg_attribute.atttypid) 
      LEFT OUTER JOIN pg_attrdef ON (   pg_attribute.attrelid = pg_attrdef.adrelid 
                                    AND pg_attribute.attnum = pg_attrdef.adnum)
     WHERE attnum > 0
       AND attrelid = ?;
    };

## 7.1 or earlier has a different description structure
}
else {

    $sql_Tables = qq{
    SELECT quote_ident('public') as namespace
         , quote_ident(relname) as tablename
         , pg_get_userbyid(relowner) AS tableowner
         , relhasindex as hasindexes
         , relhasrules as hasrules
         , reltriggers as hastriggers
         , pg_class.oid
         , obj_description(pg_class.oid) as table_description
      FROM pg_class
     WHERE (  relkind = 'r'::"char"
           OR relkind = 's'::"char"
           )
       AND relname NOT LIKE 'pg_%';
    };

    # - uses pg_class.oid
    $sql_Columns = qq{
    SELECT quote_ident(attname) as column_name
         , attlen as column_length
         , CASE
           WHEN pg_type.typname = 'int4'
                AND adsrc LIKE 'nextval(%' THEN
             'serial'
           WHEN pg_type.typname = 'int8'
                AND adsrc LIKE 'nextval(%' THEN
             'bigserial'
           ELSE
             pg_catalog.format_type(atttypid, atttypmod)
           END as column_type
         , CASE
           WHEN attnotnull IS TRUE THEN
             'NOT NULL'::text
           ELSE
             ''::text
           END as column_null
         , CASE
           WHEN pg_type.typname in ('int4', 'int8')
                AND adsrc LIKE 'nextval(%' THEN
             NULL
           ELSE
             adsrc
           END as column_default
         , description as column_description
         , attnum
      FROM pg_attribute 
                 JOIN pg_type ON (pg_type.oid = pg_attribute.atttypid) 
      LEFT OUTER JOIN pg_attrdef ON (   pg_attribute.attrelid = pg_attrdef.adrelid 
                                    AND pg_attribute.attnum = pg_attrdef.adnum)
      LEFT OUTER JOIN pg_description ON (pg_description.objoid = pg_attribute.oid)
     WHERE attnum > 0
       AND attrelid = ?;
    };
}

## New method of storing constraint keys
my $sql_Primary_Keys;
if ($pgversion >= 70300)
{
    $sql_Primary_Keys = qq{
    SELECT pg_catalog.quote_ident(conname) AS constraint_name
         , pg_catalog.pg_get_indexdef(d.objid) AS constraint_definition
         , CASE
           WHEN contype = 'p' THEN
             'PRIMARY KEY'
           ELSE
             'UNIQUE'
           END as constraint_type
         , conkey[2] is not null as multicolumn
      FROM pg_catalog.pg_constraint AS c
      JOIN pg_catalog.pg_depend AS d ON (d.refobjid = c.oid)
     WHERE contype IN ('p', 'u')
	   AND deptype = 'i'
       AND conrelid = ?;
    };

} else {
    # - uses pg_class.oid
    $sql_Primary_Keys = qq{
    SELECT quote_ident(i.relname) AS constraint_name
         , pg_get_indexdef(pg_index.indexrelid) AS constraint_definition
         , CASE
           WHEN indisprimary THEN
             'PRIMARY KEY'
           ELSE
             'UNIQUE'
           END as constraint_type
         , EXISTS (SELECT TRUE
              FROM pg_index x
                 , pg_attribute a
                 , pg_class c2
                 , pg_class i2 
             WHERE a.attrelid = i.oid
               AND c2.oid = x.indrelid
               AND i2.oid = x.indexrelid
               AND x.indisunique IS TRUE
               AND i2.oid = i.oid
           ) as multicolumn
      FROM pg_index
         , pg_class as i 
     WHERE i.oid = pg_index.indexrelid
       AND pg_index.indisunique
       AND pg_index.indrelid = ?;
    };
}

if ( $pgversion >= 70300 ) {
    $sql_Foreign_Keys = qq{
    SELECT pg_constraint.oid
         , pg_catalog.quote_ident(nspname) as namespace
         , pg_catalog.quote_ident(conname) as constraint_name
         , conkey as constraint_key
         , confkey as constraint_fkey
         , confrelid as foreignrelid
      FROM pg_catalog.pg_constraint
      JOIN pg_catalog.pg_class ON (pg_class.oid = conrelid)
      JOIN pg_catalog.pg_namespace ON (relnamespace = pg_namespace.oid)
     WHERE contype = 'f'
       AND conrelid = ?;
    };

    $sql_Foreign_Key_Arg = qq{
     SELECT pg_catalog.quote_ident(attname) as attribute_name
          , pg_catalog.quote_ident(relname) as relation_name
          , pg_catalog.quote_ident(nspname) as namespace
       FROM pg_catalog.pg_attribute
       JOIN pg_catalog.pg_class ON (pg_class.oid = attrelid)
       JOIN pg_catalog.pg_namespace ON (relnamespace = pg_namespace.oid)
      WHERE attrelid = ?
        AND attnum = ?;
    };
}
else {

    # - uses pg_class.oid
    $sql_Foreign_Keys = qq{
    SELECT oid
         , quote_ident('public') as namespace
         , quote_ident(tgname) as constraint_name
         , tgnargs as number_args
         , tgargs as args
      FROM pg_trigger
     WHERE tgisconstraint = TRUE
       AND tgtype = 21
       AND tgrelid = ?;
    };

    $sql_Foreign_Key_Arg = qq{SELECT TRUE WHERE ? = 0 and ? = 0;};
}

# - uses pg_class.oid
if ( $pgversion >= 70300 ) {
    $sql_Constraint = qq{
    SELECT 'CHECK ' || pg_catalog.substr(consrc, 2, length(consrc) - 2) as constraint_source
         , pg_catalog.quote_ident(conname) as constraint_name
      FROM pg_constraint
     WHERE conrelid = ?
       AND contype = 'c';
    };
}
else {
    $sql_Constraint = qq{
    SELECT 'CHECK ' || substr(rcsrc, 2, length(rcsrc) - 2) as constraint_source
         , quote_ident(rcname) as constraint_name
      FROM pg_relcheck
     WHERE rcrelid = ?;
    };
}

# Query for function information
if ( $pgversion >= 70300 ) {
    $sql_Function = qq{
	  SELECT pg_catalog.quote_ident(proname) as function_name
           , pg_catalog.quote_ident(nspname) as namespace
	       , pg_catalog.quote_ident(lanname) as language_name
	       , pg_catalog.obj_description(pg_proc.oid, 'pg_proc') as comment
           , proargtypes as function_args
        FROM pg_catalog.pg_proc
        JOIN pg_catalog.pg_language ON (pg_language.oid = prolang)
        JOIN pg_catalog.pg_namespace ON (pronamespace = pg_namespace.oid)
       WHERE pg_namespace.nspname != '$system_schema';
	};

    $sql_FunctionArg = qq{
	  SELECT pg_catalog.quote_ident(nspname) as namespace
	       , pg_catalog.format_type(pg_type.oid, typlen) as type_name
	    FROM pg_catalog.pg_type
	    JOIN pg_catalog.pg_namespace ON (pg_namespace.oid = typnamespace)
       WHERE pg_type.oid = ?;
	};
}
else {

    # Don't feel like writing these out at the moment.
    # Use junk placeholders.
    $sql_Function = qq{
    SELECT quote_ident(proname) as function_name
         , quote_ident('public') as namespace
         , quote_ident(lanname) as language_name
         , description as comment
         , proargtypes as function_args
      FROM pg_proc
      JOIN pg_language ON (pg_language.oid = prolang)
      LEFT OUTER JOIN pg_description ON (objoid = pg_proc.oid)
     WHERE pg_proc.oid > 16000
       AND proname != 'plpgsql_call_handler';
     };

    $sql_FunctionArg = qq{
    SELECT quote_ident('public') as namespace
         , format_type(pg_type.oid, typlen) as type_name
      FROM pg_type
     WHERE pg_type.oid = ?;
    };
}

if ( $pgversion >= 70300 ) {
    $sql_Schema = qq{
    SELECT pg_catalog.obj_description(oid, 'pg_namespace') as comment
         , pg_catalog.quote_ident(nspname) as namespace
      FROM pg_catalog.pg_namespace;
    };
}
else {
    $sql_Schema = qq{SELECT TRUE WHERE TRUE = FALSE;};
}

if ( $pgversion >= 70300 ) {
    $sql_Database = qq{
    SELECT pg_catalog.obj_description(oid, 'pg_database') as comment
      FROM pg_catalog.pg_database
     WHERE datname = '$database';
    };
}
elsif ($pgversion == 70200 ) {
    $sql_Database = qq{
    SELECT obj_description(oid, 'pg_database') as comment
      FROM pg_database
     WHERE datname = '$database';
    };
}
else {
    $sql_Database = qq{ SELECT TRUE as comment WHERE TRUE = FALSE;};
}

my $sth_Database        = $dbh->prepare($sql_Database);
my $sth_Tables          = $dbh->prepare($sql_Tables);
my $sth_Foreign_Keys    = $dbh->prepare($sql_Foreign_Keys);
my $sth_Foreign_Key_Arg = $dbh->prepare($sql_Foreign_Key_Arg);
my $sth_Primary_Keys    = $dbh->prepare($sql_Primary_Keys);
my $sth_Columns         = $dbh->prepare($sql_Columns);
my $sth_Constraint      = $dbh->prepare($sql_Constraint);
my $sth_Function        = $dbh->prepare($sql_Function);
my $sth_FunctionArg     = $dbh->prepare($sql_FunctionArg);
my $sth_Schema          = $dbh->prepare($sql_Schema);

my %structure;
my %struct;

# Fetch Database info
$sth_Database->execute();
my $dbinfo = $sth_Database->fetchrow_hashref;
if ( defined($dbinfo) ) {
    $struct{'DATABASE'}{$database}{'COMMENT'} = $dbinfo->{'comment'};
}

# Fetch tables and all things bound to tables
$sth_Tables->execute();
while ( my $tables = $sth_Tables->fetchrow_hashref ) {
    my $table_oid  = $tables->{'oid'};
    my $table_name = $tables->{'tablename'};

    my $group = $tables->{'namespace'};

  EXPRESSIONFOUND:

    ## Store permissions
    my $acl = $tables->{'relacl'};

    # Empty acl groups cause serious issues.
    $acl ||= '';

    # Strip array forming 'junk'.
    $acl =~ s/^{//g;
    $acl =~ s/}$//g;
    $acl =~ s/"//g;

    foreach ( split ( /\,/, $acl ) ) {
        my ( $user, $permissions ) = split ( /=/, $_ );

        if ( defined($permissions) ) {
            if ( $user eq '' ) {
                $user = 'PUBLIC';
            }

            # Break down permissions to individual flags
            if ( $permissions =~ /a/ ) {
                $structure{$group}{$table_name}{'ACL'}{$user}{'INSERT'} = 1;
            }

            if ( $permissions =~ /r/ ) {
                $structure{$group}{$table_name}{'ACL'}{$user}{'SELECT'} = 1;
            }

            if ( $permissions =~ /w/ ) {
                $structure{$group}{$table_name}{'ACL'}{$user}{'UPDATE'} = 1;
            }

            if ( $permissions =~ /d/ ) {
                $structure{$group}{$table_name}{'ACL'}{$user}{'DELETE'} = 1;
            }

            if ( $permissions =~ /R/ ) {
                $structure{$group}{$table_name}{'ACL'}{$user}{'RULE'} = 1;
            }

            if ( $permissions =~ /x/ ) {
                $structure{$group}{$table_name}{'ACL'}{$user}{'REFERENCES'} = 1;
            }

            if ( $permissions =~ /t/ ) {
                $structure{$group}{$table_name}{'ACL'}{$user}{'TRIGGER'} = 1;
            }
        }
    }

    ## Store table description
    $structure{$group}{$table_name}{'DESCRIPTION'} =
      $tables->{'table_description'};

    ## Store constraints
    $sth_Constraint->execute($table_oid);
    while ( my $cols = $sth_Constraint->fetchrow_hashref ) {
        my $constraint_name = $cols->{'constraint_name'};
        $structure{$group}{$table_name}{'CONSTRAINT'}{$constraint_name} =
          $cols->{'constraint_source'};

        #    print "        $constraint_name\n";
    }

    $sth_Columns->execute($table_oid);
    my $i = 1;
    while ( my $cols = $sth_Columns->fetchrow_hashref ) {
        my $column_name = $cols->{'column_name'};
        $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'ORDER'} =
          $cols->{'attnum'};
        $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'PRIMARY KEY'} =
          0;
        $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'FK'}   = '';
        $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'TYPE'} =
          $cols->{'column_type'};
        $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'NULL'} =
          $cols->{'column_null'};
        $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'DESCRIPTION'} =
          $cols->{'column_description'};
        $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'DEFAULT'} =
          $cols->{'column_default'};

        #    print "        $table_name -> $column_name\n";
        #    print $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'TYPE'} ."\n\n";
    }

    $sth_Primary_Keys->execute($table_oid);
    while ( my $pricols = $sth_Primary_Keys->fetchrow_hashref ) {
        my $multicolumn = $pricols->{'multicolumn'};
        my $index_type    = $pricols->{'constraint_type'};
        my $index_name    = $pricols->{'constraint_name'};
		my $indexdef	  = $pricols->{'constraint_definition'};

		# Fetch the column list
		my $column_list = $indexdef;
		$column_list =~ s/.*\(([^)]+)\).*/$1/g;

		# Override multicolumn with a check for commas
		my @collist = split(',', $column_list);

		$multicolumn = $#collist;

        if ( $multicolumn == 0 ) {
            $structure{$group}{$table_name}{'COLUMN'}{$column_list}
              {$index_type} = 1;
        }
        else {

			$structure{$group}{$table_name}{'CONSTRAINT'}{$index_name} =
				"$index_type ($column_list)";
        }

        #    print "   PK	$index_type	$column_number	$table_name	$column_name\n";
    }
    $sth_Foreign_Keys->execute($table_oid);
    while ( my $forcols = $sth_Foreign_Keys->fetchrow_hashref ) {
        my $column_oid      = $forcols->{'oid'};
        my $constraint_name = $forcols->{'constraint_name'};

        if ( $pgversion >= 70300 ) {
            my $fkey   = $forcols->{'constraint_fkey'};
            my $keys   = $forcols->{'constraint_key'};
            my $frelid = $forcols->{'foreignrelid'};

            $fkey =~ s/^{//g;
            $fkey =~ s/}$//g;
            $fkey =~ s/"//g;

            $keys =~ s/^{//g;
            $keys =~ s/}$//g;
            $keys =~ s/"//g;

            my @keyset  = split ( /,/, $keys );
            my @fkeyset = split ( /,/, $fkey );

            my $count   = 0;
            my $keylist = '';
            foreach my $k (@keyset) {
                $sth_Foreign_Key_Arg->execute( $table_oid, $k );

                my $row = $sth_Foreign_Key_Arg->fetchrow_hashref;

                if ( $count >= 1 ) {
                    $keylist .= ',';
                }
                $keylist .= $row->{'attribute_name'};
                $count++;
            }

            my $fkeylist = '';
            my $fgroup;
            my $ftable;
            my $fcount = 0;
            foreach my $k (@fkeyset) {
                $sth_Foreign_Key_Arg->execute( $frelid, $k );

                my $row = $sth_Foreign_Key_Arg->fetchrow_hashref;

                if ( $fcount >= 1 ) {
                    $fkeylist .= ', ';
                }
                $fkeylist .= $row->{'attribute_name'};
                $fgroup .= $row->{'namespace'};
                $ftable .= $row->{'relation_name'};
                $fcount++;
            }

            die "FKEY $constraint_name Broken" if $fcount != $count;
            if ( $count == 0 ) {
                die "FKEY $constraint_name Broken";
            }
            elsif ( $count == 1 ) {
                $structure{$group}{$table_name}{'COLUMN'}{$keylist}{'FK'} =
                  "$ftable";    #.$fcolumn_name";
                $structure{$group}{$table_name}{'COLUMN'}{$keylist}{'FKGROUP'} =
                  "$fgroup";
                $structure{$group}{$table_name}{'COLUMN'}{$keylist}
                  {'FK-COL NAME'} = "$fkeylist";
            }
            else {
                $structure{$group}{$table_name}{'CONSTRAINT'}
                  {$constraint_name} =
				"FOREIGN KEY ($keylist)".
				" REFERENCES $fgroup.$ftable ($fkeylist)";
            }
        }
        else {
            my $nargs = $forcols->{'number_args'};
            my $args  = $forcols->{'args'};

            if ( $nargs == 6 ) {
                my ( $keyname, $table, $ftable, $unspecified, $lcolumn_name,
                    $fcolumn_name )
                  = split ( /\000/, $args );

                # Account for old versions which don't handle NULL but instead return a string
                if ( !defined($ftable) ) {
                    (
                        $keyname, $table, $ftable, $unspecified, $lcolumn_name,
                        $fcolumn_name
                      )
                      = split ( /\\000/, $args );
                }

                $structure{$group}{$table_name}{'COLUMN'}{$lcolumn_name}{'FK'} =
                  "$ftable";    #.$fcolumn_name";
                $structure{$group}{$table_name}{'COLUMN'}{$lcolumn_name}
                  {'FK-COL NAME'} = "$fcolumn_name";
                $structure{$group}{$table_name}{'COLUMN'}{$lcolumn_name}
                  {'FKGROUP'} = $system_schema;

                # print "   FK   $lcolumn_name -> $ftable.$fcolumn_name\n";
            }
            elsif ( ( $nargs - 6 ) % 2 == 0 ) {
                my ( $keyname, $table, $ftable, $unspecified, $lcolumn_name,
                    $fcolumn_name, @junk )
                  = split ( /\000/, $args );

                # Account for old versions which don't handle NULL but instead return a string
                if ( !defined($ftable) ) {
                    (
                        $keyname, $table, $ftable, $unspecified, $lcolumn_name,
                        $fcolumn_name, @junk
                      )
                      = split ( /\\000/, $args );
                }

                my $key_cols = "$lcolumn_name";
                my $ref_cols = "$fcolumn_name";

                while ( $lcolumn_name = pop (@junk)
                    and $fcolumn_name = pop (@junk) )
                {

                    $key_cols .= ", $lcolumn_name";
                    $ref_cols .= ", $fcolumn_name";
                }

                $structure{$group}{$table_name}{'CONSTRAINT'}
                  {$constraint_name} =
                  "FOREIGN KEY ($key_cols) REFERENCES $ftable($ref_cols)";
            }
        }
    }
}

####
# Function Handling
$sth_Function->execute();
while ( my $functions = $sth_Function->fetchrow_hashref ) {
    my $functionname = $functions->{'function_name'} . '( ';
    my $group        = $functions->{'namespace'};
    my $comment      = $functions->{'comment'};
    my $functionargs = $functions->{'function_args'};

    my @types = split ( ' ', $functionargs );
    my $count = 0;

    foreach my $type (@types) {
        $sth_FunctionArg->execute($type);

        my $hash = $sth_FunctionArg->fetchrow_hashref;

        if ( $count > 0 ) {
            $functionname .= ', ';
        }

        if ( $hash->{'namespace'} ne $system_schema ) {
            $functionname .= $hash->{'namespace'} . '.';
        }
        $functionname .= $hash->{'type_name'};
        $count++;
    }
    $functionname .= ' )';

    $struct{'FUNCTION'}{$group}{$functionname}{'COMMENT'} = $comment;
}

####
# Schema
$sth_Schema->execute();
while ( my $schema = $sth_Schema->fetchrow_hashref ) {
    my $comment   = $schema->{'comment'};
    my $namespace = $schema->{'namespace'};

    $struct{'SCHEMA'}{$namespace}{'COMMENT'} = $comment;
}

if ( $do_uml == 1 ) {
    &write_uml_structure();
}

if ($do_dot) {
    &write_dot_file_ports();
}

if ( $do_index == 1 ) {
    &write_index_structure();
}

if ( $do_docbook == 1 ) {
    &write_docbook_structure();
}

#####################################
## write_index_structure
##
sub write_index_structure {
    sysopen( FH, $index_outputfile, O_WRONLY | O_TRUNC | O_CREAT, 0644 )
      or die "Can't open $index_outputfile: $!";

    print FH << "EoF";
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN"
   "http://www.w3.org/TR/html4/strict.dtd">
<html>
  <head>
    <title>Index for $database</title>
    <style type="text/css">
	BODY {
		color:	#000000; 
		background-color: #FFFFFF;
		font-family: Helvetica, sans-serif; 
	}

	P {
		margin-top: 5px;
		margin-bottom: 5px;
	}

	P.w3ref {
		font-size: 8pt;
		font-style: italic;
		text-align: right;
	}

	P.detail {
		font-size: 10pt;
	}

	.error {
		color: #FFFFFF;
		background-color: #FF0000;
	}

	H1, H2, H3, H4, H5, H6 {
	}

	OL {
		list-style-type: upper-alpha;
	}

	UL.topic {
		list-style-type: upper-alpha;
	}

	LI.topic {
		font-weight : bold;
	}

	HR {
		color: #00FF00;
		background-color: #808080;
	}

	TABLE {
		border-width: medium;
		padding: 3px;
		background-color: #000000;
		width: 90%;
	}

	CAPTION {
		text-transform: capitalize;
		font-weight : bold;
		font-size: 14pt;
	}

	TH {
		color: #FFFFFF;
		background-color: #000000;
		text-align: left;
	}

	TR {
		color: #000000;
		background-color: #000000;
		vertical-align: top;
	}

	TR.tr0 {
		background-color: #F0F0F0;
	}

	TR.tr1 {
		background-color: #D8D8D8;
	}

	TD {
		font-size: 12pt;
	}

	TD.col0 {
		font-weight : bold;
		width: 20%;
	}

	TD.col1 {
		font-style: italic;
		width: 15%;
	}

	TD.col2 {
		font-size: 12px;
	}
    </style>
    <link rel="stylesheet" type="text/css" media="all" href="all.css">
    <link rel="stylesheet" type="text/css" media="screen" href="screen.css">
    <link rel="stylesheet" type="text/css" media="print" href="print.css">
    <meta HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=iso-8859-1">
  </head>
  <body>
EoF

    ## Primary Index
	my @timestamp = localtime();
	print FH '<p>'. xml_safe_chars($struct{'DATABASE'}{$database}{'COMMENT'}) .'<br><br>'.
			 xml_safe_chars('Dumped on '. ($timestamp[5]+1900) .'-'.
						   ($timestamp[4]+1) .'-'.
			 			   $timestamp[3]).
		     '.</p>';
    print FH '<a name="index"><h1>Index of database - '.
			 $database .'</h1><ul>';

    foreach my $group ( sort keys %structure ) {
        print FH '<li><a name="group_' . $group . '">' . xml_safe_chars($group).
				 '</a></li><ul>';

        foreach my $table ( sort keys %{ $structure{$group} } ) {
            print FH '<li><a href="#table_' . $table . '">'. xml_safe_chars($table)
              . '</a></li>';
        }

        foreach my $function ( sort keys %{ $struct{'FUNCTION'}{$group} } ) {
            print FH '<li><a href="#function_'
              . $function . '">'
              . xml_safe_chars($function)
              . '</a></li>';
        }

        print FH '</ul>';
    }
    print FH '</ul>';

    ## Group Creation
    foreach my $group ( sort keys %structure ) {

        foreach my $table ( sort keys %{ $structure{$group} } ) {
            my $tr = 0;    # TableRow class for color alterning in rows.
            print FH '<hr><h2>Table: ';

            print FH '<a href="#group_' . $group . '">'. xml_safe_chars($group) .'</a>.';

            print FH '<a name="table_' . $table . '">'. xml_safe_chars($table) .'</a></h2>';
            if ( defined( $structure{$group}{$table}{'DESCRIPTION'} ) ) {
                print FH '<p>'.
						 xml_safe_chars($structure{$group}{$table}{'DESCRIPTION'}).
						 '</p>';
            }
            print FH '<table width="100%" cellspacing="0" cellpadding="3">
                <caption>';
            print FH xml_safe_chars($group . "." . $table) .' Structure</caption>
                <tr>
                <th>F-Key</th>
                <th>Name</th>
                <th>Type</th>
                <th>Description</th>
                </tr>';
            foreach my $column (
                sort {
                    $structure{$group}{$table}{'COLUMN'}{$a}
                      {'ORDER'} <=> $structure{$group}{$table}{'COLUMN'}{$b}
                      {'ORDER'}
                }
                keys %{ $structure{$group}{$table}{'COLUMN'} }
              )
            {

                print FH '<tr class="tr' . ( $tr++ % 2 ) . '">';

                # Test for and resolv foreign keys
                if (
                    defined(
                        $structure{$group}{$table}{'COLUMN'}{$column}{'FK'}
                    )
                    && $structure{$group}{$table}{'COLUMN'}{$column}{'FK'} ne ''
                  )
                {

                    my $fk_group;
                    foreach my $fk_search_group ( sort keys %structure ) {
                        foreach my $fk_search_table (
                            sort keys %{ $structure{$fk_search_group} } )
                        {
                            if ( $fk_search_table eq
                                $structure{$group}{$table}{'COLUMN'}{$column}
                                {'FK'} )
                            {
                                $fk_group = $fk_search_group;

                                # Found our key, lets get out.
                                goto FKFOUND;
                            }
                        }
                    }
                  FKFOUND:

                    # Test for whether we found a good Foreign key reference or not.
                    if ( !defined($fk_group) ) {
                        print "BAD FOREIGN KEY FROM $table TO "
                          . $structure{$group}{$table}{'COLUMN'}{$column}{'FK'}
                          . "\n";
                        print "Errors will occur due to this.".
							  " Please fix them and re-run $basename\n";
                    }

                    print FH '<td><a href="#table_'
                      . $structure{$group}{$table}{'COLUMN'}{$column}{'FK'}
                      . '">';

                    print FH $fk_group . ' -> ';

                    print FH $structure{$group}{$table}{'COLUMN'}{$column}{'FK'}
                      . '</a>
                  </td>';

                }
                else {
                    print FH '<td></td>';
                }

                print FH '<td>' . $column . '</td>
                  <td>'
                  . xml_safe_chars($structure{$group}{$table}{'COLUMN'}{$column}{'TYPE'})
                  . '</td><td>';

                my $marker_wasdata = 0;
                if ( $structure{$group}{$table}{'COLUMN'}{$column}{'NULL'} ne
                    '' )
                {
                    print FH '<i>'.
                      xml_safe_chars($structure{$group}{$table}{'COLUMN'}{$column}{'NULL'});
                    $marker_wasdata = 1;
                }

                if (
                    defined(
                        $structure{$group}{$table}{'COLUMN'}{$column}
                          {'PRIMARY KEY'}
                    )
                    && $structure{$group}{$table}{'COLUMN'}{$column}
                    {'PRIMARY KEY'} == 1
                  )
                {
                    if ( $marker_wasdata == 1 ) {
                        print FH ' PRIMARY KEY ';
                    }
                    else {
                        print FH '<i>PRIMARY KEY ';
                        $marker_wasdata = 1;
                    }
                }

                if (
                    exists(
                        $structure{$group}{$table}{'COLUMN'}{$column}{'UNIQUE'}
                    )
                  )
                {
                    if ( $marker_wasdata == 1 ) {
                        print FH ' UNIQUE ';
                    }
                    else {
                        print FH '<i>UNIQUE ';
                        $marker_wasdata = 1;
                    }
                }

                if (
                    defined(
                        $structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'}
                    )
                  )
                {
                    if ( $marker_wasdata == 1 ) {
                        print FH ' default '
                          . xml_safe_chars($structure{$group}{$table}{'COLUMN'}{$column}
                          {'DEFAULT'});
                    }
                    else {
                        print FH '<i>default '
                          . xml_safe_chars($structure{$group}{$table}{'COLUMN'}{$column}
                          {'DEFAULT'});
                        $marker_wasdata = 1;
                    }
                }

                if ( $marker_wasdata == 1 ) {
                    print FH '</i>';
                }

                if (
                    defined(
                        $structure{$group}{$table}{'COLUMN'}{$column}
                          {'DESCRIPTION'}
                    )
                  )
                {
                    if ( $marker_wasdata == 1 ) {
                        print FH '<br><br>';
                    }
                    print FH xml_safe_chars($structure{$group}{$table}{'COLUMN'}{$column}
                      {'DESCRIPTION'});
                }

                print FH '</td></tr>';

            }
            print FH '</table>';

            # Reset color counter
            $tr = 0;

            # Constraint List
            my $constraint_marker = 0;
            foreach my $constraint (
                sort keys %{ $structure{$group}{$table}{'CONSTRAINT'} } )
            {
                if ( $constraint_marker == 0 ) {
                    print FH
						'<p>&nbsp;</p><table width="100%"'.
						' cellspacing="0" cellpadding="3">
                    <caption>';

                    print FH xml_safe_chars($group . '.' . $table) .' Constraints</caption>
                    <tr>
                    <th>Name</th>
                    <th>Constraint</th>
                    </tr>';
                    $constraint_marker = 1;
                }
                print FH '<tr class="tr'
                  . ( $tr++ % 2 )
                  . '"><td>'
                  . xml_safe_chars($constraint) .'</td>
                      <td>'
                  . xml_safe_chars($structure{$group}{$table}{'CONSTRAINT'}{$constraint})
                  . '</td></tr>';
            }
            if ( $constraint_marker == 1 ) {
                print FH '</table>';
            }

            # Foreign Key Discovery
            my $fk_marker = 0;
            foreach my $fk_group ( sort keys %structure ) {
                foreach my $fk_table ( sort keys %{ $structure{$fk_group} } ) {
                    foreach my $fk_column (
                        sort
                        keys %{ $structure{$fk_group}{$fk_table}{'COLUMN'} } )
                    {
                        if (
                            defined(
                                $structure{$fk_group}{$fk_table}{'COLUMN'}
                                  {$fk_column}{'FK'}
                            )
                            && $structure{$fk_group}{$fk_table}{'COLUMN'}
                            {$fk_column}{'FK'} eq $table
                          )
                        {
                            if ( $fk_marker == 0 ) {
                                print FH
								'<p>Tables referencing this one via'.
								' Foreign Key Constraints:</p><ul>';
                                $fk_marker = 1;
                            }
                            print FH '<li><a href="#table_' . $fk_table . '">';
                            print FH xml_safe_chars($fk_group .'.'.
                            		$fk_table) . '</a></li>';
                        }
                    }
                }
            }

            if ( $fk_marker == 1 ) {
                print FH '</ul>';
            }

            # Reset color counter
            $tr = 0;

            # List off permissions
            my $perminserted = 0;
            foreach
              my $user ( sort keys %{ $structure{$group}{$table}{'ACL'} } )
            {

                # Lets not list the user unless they have atleast one permission
                my $foundone = 0;
                foreach my $perm (
                    sort keys %{ $structure{$group}{$table}{'ACL'}{$user} } )
                {
                    if ( $structure{$group}{$table}{'ACL'}{$user}{$perm} == 1 )
                    {
                        $foundone = 1;
                    }
                }

                if ( $foundone == 1 ) {

                    # Have we started the section yet?
                    if ( $perminserted == 0 ) {
                        print FH
'<p>&nbsp;</p><table width="100%"'.' cellspacing="0" cellpadding="3">';
                        print FH '<caption>'
                          . xml_safe_chars(
                            'Permissions which apply to ' . $table )
                          . '</caption>';
                        print FH '<tr>';
                        print FH '<th>' . xml_safe_chars('User') . '</th>';
                        print FH '<th><center>'
                          . xml_safe_chars('Select')
                          . '</center></th>';
                        print FH '<th><center>'
                          . xml_safe_chars('Insert')
                          . '</center></th>';
                        print FH '<th><center>'
                          . xml_safe_chars('Update')
                          . '</center></th>';
                        print FH '<th><center>'
                          . xml_safe_chars('Delete')
                          . '</center></th>';
                        print FH '<th><center>'
                          . xml_safe_chars('Rule')
                          . '</center></th>';
                        print FH '<th><center>'
                          . xml_safe_chars('Reference')
                          . '</center></th>';
                        print FH '<th><center>'
                          . xml_safe_chars('Trigger')
                          . '</center></th>';
                        print FH '</tr>';

                        $perminserted = 1;
                    }

                    print FH '<tr class="tr' . ( $tr++ % 2 ) . '">';
                    print FH '<td>' . xml_safe_chars($user) . '</td>';

                    print FH '<td>';
                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'SELECT'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}{'SELECT'} ==
                        1
                      )
                    {
                        print FH '<center>&diams;</center>';
                    }
                    print FH '</td>';

                    print FH '<td>';
                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'INSERT'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}{'INSERT'} ==
                        1
                      )
                    {
                        print FH '<center>&diams;</center>';
                    }
                    print FH '</td>';

                    print FH '<td>';
                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'UPDATE'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}{'UPDATE'} ==
                        1
                      )
                    {
                        print FH '<center>&diams;</center>';
                    }
                    print FH '</td>';

                    print FH '<td>';
                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'DELETE'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}{'DELETE'} ==
                        1
                      )
                    {
                        print FH '<center>&diams;</center>';
                    }
                    print FH '</td>';

                    print FH '<td>';
                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'RULE'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}{'RULE'} == 1
                      )
                    {
                        print FH '<center>&diams;</center>';
                    }
                    print FH '</td>';

                    print FH '<td>';
                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}
                              {'REFERENCES'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}
                        {'REFERENCES'} == 1
                      )
                    {
                        print FH '<center>&diams;</center>';
                    }
                    print FH '</td>';

                    print FH '<td>';
                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'TRIGGER'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}
                        {'TRIGGER'} == 1
                      )
                    {
                        print FH '&diams;';
                    }
                    print FH '</td></tr>';
                }
            }
            if ( $perminserted != 0 ) {
                print FH '</table>';
            }

            print FH '<p><a href="#index">Index</a>';
            print FH ' - <a href="#group_' . $group
              . '">Schema '
              . $group . '</a>';
            print FH '</p>';
        }

        ###
        ## We've gone through the table structure, now lets take
        ## a look at user functions.
        foreach my $function ( sort keys %{ $struct{'FUNCTION'}{$group} } ) {
            my $comment = $struct{'FUNCTION'}{$group}{$function}{'COMMENT'};
            $comment = 'NO COMMENT' if !defined($comment);

            print FH '<hr><h2>Function: ';

            print FH '<a href="#group_' . $group . '">' . $group . '</a>.';

            print FH '<a name="function_'
              . $function . '">'
              . $function
              . '</a></h2>';

            print FH '<pre>' . xml_safe_chars($comment) . '</pre>';
        }

    }
    print FH '<p class="w3ref">'.
            '<a href="http://validator.w3.org/check/referer">'.
			'W3C HTML 4.01 Strict</a></p>';
    print FH '</body></html>';
}

#####################################
## write_dot_file_ports()
##
sub write_dot_file_ports {

    sysopen( FH, $dot_outputfile, O_WRONLY | O_TRUNC | O_CREAT, 0644 )
      or die "Can't open $dot_outputfile: $!";

    print FH 'digraph g {
graph [
rankdir = "LR",
concentrate = true,
ratio = 1.0
];
node [
fontsize = "10",
shape = record
];
edge [
];
';

    my $colNum;
    foreach my $group ( sort keys %structure ) {

        foreach my $table ( sort keys %{ $structure{$group} } ) {
            my @columns = sort {
                $structure{$group}{$table}{'COLUMN'}{$a}
                  {'ORDER'} <=> $structure{$group}{$table}{'COLUMN'}{$b}
                  {'ORDER'}
            } keys %{ $structure{$group}{$table}{'COLUMN'} };
            my @graphCols;
            my $ref_table;
            foreach my $column (@columns) {
                my $type =
                  $structure{$group}{$table}{'COLUMN'}{$column}{'TYPE'};
                $type =~ tr/a-z/A-Z/;
                $colNum =
                  $structure{$group}{$table}{'COLUMN'}{$column}{'ORDER'};
                if ( $structure{$group}{$table}{'COLUMN'}{$column}{'FK'} ne '' )
                {
                    $ref_table =
                      $structure{$group}{$table}{'COLUMN'}{$column}{'FK'};
                }
                push ( @graphCols, qq /| <col$colNum> $column:  $type\\l/ );
            }

            print FH qq /$table [shape = record, label = "\\N /;
            print FH join ( ' ', @graphCols );
            print FH qq/" ];\n/;
        }
    }

    foreach my $group ( sort keys %structure ) {

        foreach my $table ( sort keys %{ $structure{$group} } ) {
            my @columns = sort {
                $structure{$group}{$table}{'COLUMN'}{$a}
                  {'ORDER'} <=> $structure{$group}{$table}{'COLUMN'}{$b}
                  {'ORDER'}
            } keys %{ $structure{$group}{$table}{'COLUMN'} };
            foreach my $column (@columns) {
                if ( $structure{$group}{$table}{'COLUMN'}{$column}{'FK'} ne '' )
                {
                    my $ref_table =
                      $structure{$group}{$table}{'COLUMN'}{$column}{'FK'};
                    my $ref_column =
                      $structure{$group}{$table}{'COLUMN'}{$column}
                      {'FK-COL NAME'};
                    my $ref_group =
                      $structure{$group}{$table}{'COLUMN'}{$column}{'FKGROUP'};
                    my $ref_con =
                      $structure{$ref_group}{$ref_table}{'COLUMN'}{$ref_column}
                      {'ORDER'};
                    my $key_con =
                      $structure{$group}{$table}{'COLUMN'}{$column}{'ORDER'};
                    print FH "$table:col$key_con -> $ref_table:col$ref_con;\n";
                }
            }
        }
    }
    print FH "\n}\n";
}

#####################################
## write_uml_structure
##
sub write_uml_structure {
    sysopen( FH, $uml_outputfile, O_WRONLY | O_TRUNC | O_CREAT, 0644 )
      or die "Can't open $uml_outputfile: $!";

    print FH '<?xml version="1.0" encoding="UTF-8"?>
<dia:diagram xmlns:dia="http://www.lysator.liu.se/~alla/dia/">
  <dia:layer name="Background" visible="true">
';

    my $id;
    my %tableids;

    foreach my $group ( sort keys %structure ) {
        my @keylist = keys %structure;

        # Schema's aren't grouped unless there is more than one.
        if ( $#keylist >= 1 ) {
            print FH '
      <dia:group>';
        }

        # Run through the list of tables in this schema.
        foreach my $table ( sort keys %{ $structure{$group} } ) {

            $tableids{$table} = $id++;

            my $constraintlist = "";
            foreach my $constraintname (
                sort keys %{ $structure{$group}{$table}{'CONSTRAINT'} } )
            {
                my $constraint =
                  $structure{$group}{$table}{'CONSTRAINT'}{$constraintname};

                # Shrink constraints to something managable
                $constraint =~ s/^(.{30}).{5,}(.{5})$/$1 ... $2/g;

                $constraintlist .= '
        <dia:composite type="umloperation">
          <dia:attribute name="name">
            <dia:string>##</dia:string>
          </dia:attribute>
          <dia:attribute name="visibility">
            <dia:enum val="3"/>
          </dia:attribute>
          <dia:attribute name="abstract">
            <dia:boolean val="false"/>
          </dia:attribute>
          <dia:attribute name="class_scope">
            <dia:boolean val="false"/>
          </dia:attribute>
          <dia:attribute name="parameters">
            <dia:composite type="umlparameter">
              <dia:attribute name="name">
                <dia:string>'
                  . xml_safe_chars( '#' . $constraint . '#' )
                  . '</dia:string>
              </dia:attribute>
              <dia:attribute name="value">
                <dia:string/>
              </dia:attribute>
              <dia:attribute name="kind">
                <dia:enum val="0"/>
              </dia:attribute>
            </dia:composite>
          </dia:attribute>
        </dia:composite>';
            }

            my $columnlist = "";
            foreach my $column (
                sort {
                    $structure{$group}{$table}{'COLUMN'}{$a}
                      {'ORDER'} <=> $structure{$group}{$table}{'COLUMN'}{$b}
                      {'ORDER'}
                }
                keys %{ $structure{$group}{$table}{'COLUMN'} }
              )
            {
                my $currentcolumn;

                if ( $structure{$group}{$table}{'COLUMN'}{$column}
                    {'PRIMARY KEY'} == 1 )
                {
                    $currentcolumn .= "PK ";
                }
                else {
                    $currentcolumn .= "   ";
                }

                if ( $structure{$group}{$table}{'COLUMN'}{$column}{'FK'} eq '' )
                {
                    $currentcolumn .= "   ";
                }
                else {
                    $currentcolumn .= "FK ";
                }

                $currentcolumn .= "$column";

                my $type =
                  $structure{$group}{$table}{'COLUMN'}{$column}{'TYPE'};
                $type =~ tr/a-z/A-Z/;

                $columnlist .= '
        <dia:composite type="umlattribute">
          <dia:attribute name="name">
            <dia:string>'
                  . xml_safe_chars( '#' . $currentcolumn . '#' )
                  . '</dia:string>
          </dia:attribute>
          <dia:attribute name="type">
            <dia:string>' . xml_safe_chars( '#' . $type . '#' ) . '</dia:string>
          </dia:attribute>';
                if (
                    !defined(
                        $structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'}
                    )
                  )
                {
                    $columnlist .= '
          <dia:attribute name="value">
            <dia:string/>
          </dia:attribute>';
                }
                else {

                    # Shrink the default if necessary
                    my $default =
                      $structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'};
                    $default =~ s/^(.{17}).{5,}(.{5})$/$1 ... $2/g;

                    $columnlist .= '
          <dia:attribute name="value">
            <dia:string>'
                      . xml_safe_chars( '#' . $default . '#' )
                      . '</dia:string>
          </dia:attribute>';
                }

                $columnlist .= '
          <dia:attribute name="visibility">
            <dia:enum val="3"/>
          </dia:attribute>
          <dia:attribute name="abstract">
            <dia:boolean val="false"/>
          </dia:attribute>
          <dia:attribute name="class_scope">
            <dia:boolean val="false"/>
          </dia:attribute>
        </dia:composite>';
            }
            print FH '
    <dia:object type="UML - Class" version="0" id="O' . $tableids{$table} . '">
      <dia:attribute name="name">
        <dia:string>' . xml_safe_chars( '#' . $table . '#' ) . '</dia:string>
      </dia:attribute>';
            if ( $#keylist >= 1 ) {
                print FH '
      <dia:attribute name="stereotype">
        <dia:string>';
                print FH xml_safe_chars( '#' . $group . '#' );
                print FH '</dia:string>
      </dia:attribute>';
            }
            print FH '
      <dia:attribute name="abstract">
        <dia:boolean val="false"/>
      </dia:attribute>
      <dia:attribute name="suppress_attributes">
        <dia:boolean val="false"/>
      </dia:attribute>
      <dia:attribute name="suppress_operations">
        <dia:boolean val="false"/>
      </dia:attribute>
      <dia:attribute name="visible_attributes">
        <dia:boolean val="true"/>
      </dia:attribute>
      <dia:attribute name="attributes">' . $columnlist . '</dia:attribute>';

            if ( $constraintlist eq '' ) {
                print FH '
      <dia:attribute name="visible_operations">
        <dia:boolean val="false"/>
      </dia:attribute>
      <dia:attribute name="operations"/>';
            }
            else {
                print FH '
      <dia:attribute name="visible_operations">
        <dia:boolean val="true"/>
      </dia:attribute>
      <dia:attribute name="operations">' . $constraintlist . '
      </dia:attribute>';
            }

            print FH '
      <dia:attribute name="template">
        <dia:boolean val="false"/>
      </dia:attribute>
      <dia:attribute name="templates"/>
    </dia:object>';
        }

        # Schema's aren't grouped unless there is more than one.
        if ( $#keylist >= 1 ) {
            print FH '
      </dia:group>';
        }
    }

    # Link the various components together via the template.
    foreach my $group ( sort keys %structure ) {
        foreach my $table ( sort keys %{ $structure{$group} } ) {

            foreach my $column (
                sort {
                    $structure{$group}{$table}{'COLUMN'}{$a}
                      {'ORDER'} <=> $structure{$group}{$table}{'COLUMN'}{$b}
                      {'ORDER'}
                }
                keys %{ $structure{$group}{$table}{'COLUMN'} }
              )
            {

                if ( $structure{$group}{$table}{'COLUMN'}{$column}{'FK'} ne '' )
                {

                    print FH '
      <dia:object type="UML - Constraint" version="0" id="O' . $id++ . '">
      <dia:attribute name="constraint">
        <dia:string>' . xml_safe_chars( '#' . $column . '#' ) . '</dia:string>
      </dia:attribute>
      <dia:connections>';
                    my $ref_table =
                      $structure{$group}{$table}{'COLUMN'}{$column}{'FK'};
                    my $ref_group =
                      $structure{$group}{$table}{'COLUMN'}{$column}{'FKGROUP'};
                    my $ref_column =
                      $structure{$group}{$table}{'COLUMN'}{$column}
                      {'FK-COL NAME'};
                    my $ref_con =
                      6 + ( $structure{$ref_group}{$ref_table}{'COLUMN'}
                          {$ref_column}{'ORDER'} * 2 );
                    my $key_con = 7 +
                      ( $structure{$group}{$table}{'COLUMN'}{$column}{'ORDER'} *
                          2 );
                    print FH '
        <dia:connection handle="0" to="O'
                      . $tableids{$table}
                      . '" connection="'
                      . $key_con . '"/>
        <dia:connection handle="1" to="O'
                      . $tableids{$ref_table}
                      . '" connection="'
                      . $ref_con . '"/>
      </dia:connections>
    </dia:object>';
                }
            }
        }
    }

    print FH '
  </dia:layer>
</dia:diagram>';

}

#####################################
## write_docbook_structure()
##
sub write_docbook_structure {

    sysopen( FH, $docbook_outputfile, O_WRONLY | O_TRUNC | O_CREAT, 0644 )
      or die "Can't open $docbook_outputfile: $!";

    print FH '<book id="database.'
      . sgml_safe_id($database)
      . '" xreflabel="'
      . xml_safe_chars($database)
      . ' database schema">';
    print FH "\n<title>" . xml_safe_chars("$database Model") . "</title>\n";

    # Output a DB comment.
    if ( defined( $struct{'DATABASE'}{$database}{'COMMENT'} ) ) {
        print FH xml_safe_chars( $struct{'DATABASE'}{$database}{'COMMENT'} );
    }

    ####
    ## Group Creation
    foreach my $group ( sort keys %structure ) {

        ####
        # Show the schema comment
        print FH '<chapter id="'
          . sgml_safe_id("$group")
          . '.schema'
          . '" xreflabel="'
          . $group . '">';
        print FH '<title>' . xml_safe_chars("Schema $group") . "</title>\n";

        print FH '<para>'
          . xml_safe_chars( $struct{'SCHEMA'}{$group}{'COMMENT'} )
          . "</para>\n";

        foreach my $table ( sort keys %{ $structure{$group} } ) {

            # Table section identifier
            print FH '<section id="'
              . sgml_safe_id("$group.table.$table")
              . '" xreflabel="'
              . xml_safe_chars("$group.$table") . '">';

            # Section Title
            print FH '<title>' . xml_safe_chars($table) . "</title>\n";

            # Relation Description
            if ( defined( $structure{$group}{$table}{'DESCRIPTION'} ) ) {
                print FH '<para>'
                  . xml_safe_chars( $structure{$group}{$table}{'DESCRIPTION'} )
                  . "</para>\n";
            }

            # Table structure
            print FH '<para><variablelist><title>'
              . xml_safe_chars("Structure of $table")
              . '</title>';

            foreach my $column (
                sort {
                    $structure{$group}{$table}{'COLUMN'}{$a}
                      {'ORDER'} <=> $structure{$group}{$table}{'COLUMN'}{$b}
                      {'ORDER'}
                }
                keys %{ $structure{$group}{$table}{'COLUMN'} }
              )
            {

                print FH '<varlistentry><term>'
                  . xml_safe_chars($column)
                  . "</term><listitem><para>\n"
                  . xml_safe_chars(
                    $structure{$group}{$table}{'COLUMN'}{$column}{'TYPE'} );

                if ( $structure{$group}{$table}{'COLUMN'}{$column}{'NULL'} ne
                    '' )
                {
                    print FH ' <literal>'
                      . xml_safe_chars("NOT NULL")
                      . '</literal>';
                }

                if (
                    defined(
                        $structure{$group}{$table}{'COLUMN'}{$column}
                          {'PRIMARY KEY'}
                    )
                    && $structure{$group}{$table}{'COLUMN'}{$column}
                    {'PRIMARY KEY'} == 1
                  )
                {

                    print FH ' <literal>'
                      . xml_safe_chars('PRIMARY KEY')
                      . '</literal>';
                }

                if (
                    exists(
                        $structure{$group}{$table}{'COLUMN'}{$column}{'UNIQUE'}
                    )
                  )
                {
                    print FH ' <literal>',
                      xml_safe_chars('UNIQUE') . '</literal>';
                }

                if (
                    defined(
                        $structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'}
                    )
                    && $structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'}
                    ne ''
                  )
                {

                    print FH ' <literal>'
                      . xml_safe_chars('DEFAULT ')
                      . $structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'}
                      . '</literal>';
                }

                if ( $structure{$group}{$table}{'COLUMN'}{$column}{'FK'} ne '' )
                {
                    print FH ' <literal>REFERENCES</literal> <xref linkend="'
                      . sgml_safe_id(
                        $structure{$group}{$table}{'COLUMN'}{$column}
                          {'FKGROUP'} )
                      . '.table.'
                      . sgml_safe_id(
                        $structure{$group}{$table}{'COLUMN'}{$column}{'FK'} )
                      . '">';
                }

                print FH '</para>';

                # Lets toss in the column description.
                if (
                    defined(
                        $structure{$group}{$table}{'COLUMN'}{$column}
                          {'DESCRIPTION'}
                    )
                  )
                {
                    print FH '<para>'
                      . xml_safe_chars(
                        $structure{$group}{$table}{'COLUMN'}{$column}
                          {'DESCRIPTION'} )
                      . "</para>\n";
                }

                print FH '</listitem></varlistentry>';
            }
            print FH '</variablelist>';

            # Constraint List
            my $constraints = 0;
            foreach my $constraint (
                sort keys %{ $structure{$group}{$table}{'CONSTRAINT'} } )
            {
                if ( $constraints == 0 ) {
                    print FH '<variablelist><title>'
                      . xml_safe_chars("Constraints on $table")
                      . "</title>\n";

                    $constraints++;
                }
                print FH '<varlistentry><term>'
                  . xml_safe_chars($constraint)
                  . "</term>\n<listitem><para>"
                  . xml_safe_chars(
                    $structure{$group}{$table}{'CONSTRAINT'}{$constraint} )
                  . '</para></listitem></varlistentry>';
            }
            if ( $constraints > 0 ) {
                print FH "</variablelist>\n";
            }

            # Foreign Key Discovery
            my $fkinserted = 0;
            foreach my $fk_group ( sort keys %structure ) {
                foreach my $fk_table ( sort keys %{ $structure{$fk_group} } ) {
                    foreach my $fk_column (
                        sort
                        keys %{ $structure{$fk_group}{$fk_table}{'COLUMN'} } )
                    {
                        if (
                            defined(
                                $structure{$fk_group}{$fk_table}{'COLUMN'}
                                  {$fk_column}{'FK'}
                            )
                            && $structure{$fk_group}{$fk_table}{'COLUMN'}
                            {$fk_column}{'FK'} eq $table
                          )
                        {
                            if ( $fkinserted == 0 ) {
                                print FH '<itemizedlist>';
                                print FH '<title>'
                                  . xml_safe_chars(
                                    'Tables referencing ' . $table
                                      . ' via Foreign Key Constraints' )
                                  . "</title>\n";

                                $fkinserted = 1;
                            }

                            print FH '<listitem><para><xref linkend="'
                              . sgml_safe_id("$fk_group")
                              . '.table.'
                              . sgml_safe_id($fk_table) . '">'
                              . "</para>\n</listitem>";
                        }
                    }
                }
            }
            if ( $fkinserted != 0 ) {
                print FH "</itemizedlist>\n";
            }

            # List off permissions
            my $perminserted = 0;
            foreach
              my $user ( sort keys %{ $structure{$group}{$table}{'ACL'} } )
            {

                # Lets not list the user unless they have atleast one permission
                my $foundone = 0;
                foreach my $perm (
                    sort keys %{ $structure{$group}{$table}{'ACL'}{$user} } )
                {
                    if ( $structure{$group}{$table}{'ACL'}{$user}{$perm} == 1 )
                    {
                        $foundone = 1;
                    }
                }

                if ( $foundone == 1 ) {

                    # Have we started the section yet?
                    if ( $perminserted == 0 ) {

                        print FH '<variablelist><title>'
                          . xml_safe_chars("Permissions on $table")
                          . "</title>\n";

                        $perminserted = 1;
                    }

                    print FH '<varlistentry><term>'
                      . xml_safe_chars($user)
                      . "</term>\n<listitem><para>"
                      . '<simplelist type="inline">';

                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'SELECT'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}{'SELECT'} ==
                        1
                      )
                    {
                        print FH "<member>Select</member>\n";
                    }

                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'INSERT'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}{'INSERT'} ==
                        1
                      )
                    {
                        print FH "<member>Insert</member>\n";
                    }

                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'UPDATE'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}{'UPDATE'} ==
                        1
                      )
                    {
                        print FH "<member>Update</member>\n";
                    }

                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'DELETE'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}{'DELETE'} ==
                        1
                      )
                    {
                        print FH "<member>Delete</member>\n";
                    }

                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'RULE'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}{'RULE'} == 1
                      )
                    {
                        print FH "<member>Rule</member>\n";
                    }

                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}
                              {'REFERENCES'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}
                        {'REFERENCES'} == 1
                      )
                    {
                        print FH "<member>References</member>\n";
                    }

                    if (
                        defined(
                            $structure{$group}{$table}{'ACL'}{$user}{'TRIGGER'}
                        )
                        && $structure{$group}{$table}{'ACL'}{$user}
                        {'TRIGGER'} == 1
                      )
                    {
                        print FH "<member>Trigger</member>\n";
                    }
                    print FH "</simplelist></para></listitem></varlistentry>\n";
                }
            }
            if ( $perminserted != 0 ) {
                print FH "</variablelist>\n";
            }
            print FH "</para></section>\n";
        }

        ###
        # Function listing in the section
        foreach my $function ( sort keys %{ $struct{'FUNCTION'}{$group} } ) {
            print FH '<section id="'
              . sgml_safe_id("$group")
              . '.function.'
              . sgml_safe_id($function)
              . '" xreflabel="'
              . xml_safe_chars("$group.$function") . '">';
            print FH '<title>' . xml_safe_chars("$function") . '</title>';
            print FH '<para>'
              . xml_safe_chars(
                $struct{'FUNCTION'}{$group}{$function}{'COMMENT'} )
              . '</para>';
            print FH "</section>\n";
        }
        print FH '</chapter>';
    }
    print FH '</book>';

}

#####
# xml_safe_chars
#   Convert various characters to their 'XML Safe' version
sub xml_safe_chars {
    my $string = shift;

    if ( defined($string) ) {
        if ( $string =~ /^\@DOCBOOK/ ) {
            $string =~ s/^\@DOCBOOK//;
        }
        else {
            $string =~ s/&(?!(amp|lt|gr|apos|quot);)/&amp;/g;
            $string =~ s/</&lt;/g;
            $string =~ s/>/&gt;/g;
            $string =~ s/'/&apos;/g;
            $string =~ s/"/&quot;/g;
        }
    }
    else {
        return ('');
    }

    return ($string);
}

######
# sgml_safe_id
#   Safe SGML ID Character replacement
sub sgml_safe_id {
    my $string = shift;

    # Lets use the keyword array to prevent duplicating a non-array equivelent
    $string =~ s/\[\]/ARRAY-/g;

    # Brackets, spaces, commads, underscores are not valid 'id' characters
    # replace with as few -'s as possible.
    $string =~ s/[ "',)(_-]+/-/g;

    # Don't want a - at the end either.  It looks silly.
    $string =~ s/-$//g;

    return ($string);
}

#####
# usage
#   Usage
sub usage {
    print <<USAGE
Usage:
  $basename [options] [dbname [username]]

Options:
  -d <dbname>     Specify database name to connect to (default: $database)
  -f <file>       Specify UML (dia) output file (default: $uml_outputfile)
  -F <file>       Specify index (HTML) output file (default: $index_outputfile)
  -h <host>       Specify database server host (default: localhost)
  -p <port>       Specify database server port (default: 5432)
  -u <username>   Specify database username (default: $dbuser)
  --password=<pw> Specify database password (default: blank)

  --no-index      Do NOT generate HTML index
  --no-uml        Do NOT generate XML dia file
  --no-docbook    Do NOT generate DocBook SGML file(s)
  --no-dot        Do NOT generate directed graphs in the dot language (GraphViz)

USAGE
      ;
    exit 0;
}
