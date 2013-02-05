#!/usr/bin/perl
# $Id: postgresql_autodoc.pl,v 1.19 2001/12/18 00:37:05 rbt Exp $

# Postgres Auto-Doc Version 0.31

# Installation Steps
# ------------------
# 1.  Read License
# 2.  Group tables in large installations for ease of placement (%StereoType)


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


# Contributors
# ------------
# Rod Taylor
#   DataBase Developer
#   rod.taylor@inquent.com
#   http://www.inquent.com
#
# Andrew McMillan


# About Project
# -------------
# Written due to ERWin taking an excessive amount of time in sending
# out trial licenses.
#
# http://www.zort.ca/postgresql


use DBI;
use strict;

# Allows file locking
use Fcntl;

# Grouping Structure
# ------------------
# Tables matching these expressions will be grouped together in Dia for easy positioning.
#  Ie.  You can move the group to it's place, choose ungroup then move individual tables.

# Expand the list to fit your needs.  You'll need to use 'ungroup' in the Dia interface 
# to seperate tables again.

my %StereoType;

# Stereo Type Example.  Groups all tables beginning with user or account into StereoType 'User'
#     $StereoType{'User'} = '^(user|account)';


#
# Just Code down here -- Nothing to see
#
my $dbuser = $ENV{'USER'};
my $database = $dbuser;
my $dbpass = "";
my $dbport = "";
my $dbhost = "";
my $index_outputfile = "$database.html";
my $docbook_outputfile = "$database.sgml";
my $uml_outputfile = "$database.dia";
my $showserials = 1;

my $do_index = 1;
my $do_uml = 1;
my $do_docbook = 1;

my $dbisset = 0;
my $fileisset = 0;

my $default_group = "                   whitespace for sort order ";

for( my $i=0; $i <= $#ARGV; $i++ ) {
  ARGPARSE: for ( $ARGV[$i] ) {
    /^-d$/          && do { $database = $ARGV[++$i];
                            $dbisset = 1;
                            if (! $fileisset) {
                              $uml_outputfile = $database . '.dia';
                              $index_outputfile = $database . '.html';
                              $docbook_outputfile = $database . '.sgml';
                            }
                            last;
                          };

    /^-U$/          && do { $dbuser = $ARGV[++$i];
                            if (! $dbisset) {
                              $database = $dbuser;
                              if (! $fileisset) {
                                $uml_outputfile = $database . '.dia';
                                $index_outputfile = $database . '.html';
                                $docbook_outputfile = $database . '.sgml';
                              }
                            }
                            last;
                          };

    /^-h$/          && do { $dbhost = $ARGV[++$i];     last; };
    /^-p$/          && do { $dbport = $ARGV[++$i];     last; };
    /^--password=/  && do { $dbpass = $ARGV[++$i];     last; };

    /^-f$/          && do { $uml_outputfile = $ARGV[++$i];
                            $fileisset = 1;
                            last;
                          };

    /^-F$/          && do { $index_outputfile = $ARGV[++$i];
                            $fileisset = 1;
                            last;
                          };

    /^--no-index$/   && do { $do_index = 0;         last; };
    /^--no-uml$/     && do { $do_uml = 0;           last; };
    /^--no-docbook$/ && do { $do_docbook = 0;       last; };

    /^-S$/          && do { $showserials = 0;          last; };
    /^-s$/          && do { $showserials = 1;          last; };

    /^-\?$/         && do { usage(); };
    /^--help$/      && do { usage(); };

  }
}

if ($#ARGV <= 0) {
  print "No arguments set.  Use 'postgres_autodoc.pl --help' for help\n\nConnecting to database '$database' as user '$dbuser'\n\n";
}

my $dsn = "dbi:Pg:dbname=$database";
$dsn .= ";host=$dbhost" if ( "$dbhost" ne "" );
$dsn .= ";port=$dbport" if ( "$dbport" ne "" );

# Database Connection
# -------------------
my $dbh = DBI->connect($dsn, $dbuser, $dbpass);
# $dbh->{'AutoCommit'} = 0;


END {
  $dbh->disconnect() if $dbh;
}


my $sql_Tables = qq{
  SELECT relname as tablename
       , pg_get_userbyid(relowner) AS tableowner
       , relhasindex as hasindexes
       , relhasrules as hasrules
       , reltriggers as hastriggers
       , pg_class.oid
       , description as table_description
    FROM pg_class
  LEFT OUTER JOIN pg_description on (   pg_class.oid = pg_description.objoid
                                    AND pg_description.objsubid = 0)
   WHERE (  relkind = 'r'::"char"
         OR relkind = 's'::"char"
         )
     AND relname NOT LIKE 'pg_%';
};


# - uses pg_class.oid
my $sql_Primary_Keys = qq{
  SELECT i.relname AS index_name
       , c.relname AS index_table
       , pg_get_indexdef(pg_index.indexrelid) AS index_definition
       , pg_attribute.attname AS column_name
       , CASE
         WHEN indisprimary IS TRUE THEN
           'PRIMARY KEY'
         ELSE
           'UNIQUE'
         END as index_type
       , (SELECT count(i2.oid)
            FROM pg_index x
               , pg_attribute a
               , pg_class c2
               , pg_class i2 
           WHERE a.attrelid = i.oid
             AND c2.oid = x.indrelid
             AND i2.oid = x.indexrelid
             AND x.indisunique IS TRUE
             AND i2.oid = i.oid
         ) as index_count
    FROM pg_index
       , pg_attribute
       , pg_class as c
       , pg_class as i 
   WHERE pg_attribute.attrelid = i.oid
     AND c.oid = pg_index.indrelid
     AND i.oid = pg_index.indexrelid
     AND pg_index.indisunique IS TRUE
     AND c.oid = ?;
};


# - uses pg_class.oid
my $sql_Foreign_Keys = qq{
  SELECT oid
       , tgname as constraint_name
       , tgnargs as number_args
       , tgargs as args
    FROM pg_trigger
   WHERE tgisconstraint = TRUE
     AND tgtype = 21
     AND tgrelid = ?;
};


# - uses pg_class.oid
my $sql_Columns = qq{
  SELECT attname as column_name
       , attlen as column_length
       , CASE
         WHEN attlen = -1 THEN
            CASE 
            WHEN typname = 'varchar' THEN
                 typname || '(' || atttypmod - 4 || ')'
            WHEN typname = 'bpchar' THEN
                 'char' || '(' || atttypmod - 4 || ')'
            WHEN typname = 'numeric' THEN
                 format_type(atttypid, atttypmod)
            WHEN typname = 'text' THEN
                 typname
            END
         ELSE
              typname
         END
         as column_type
       , CASE
         WHEN attnotnull IS TRUE THEN
           'NOT NULL'::text
         ELSE
           ''::text
         END as column_null
       , adsrc as column_default
       , description as column_description
    FROM pg_attribute 
              JOIN pg_type ON (pg_type.oid = pg_attribute.atttypid) 
   LEFT OUTER JOIN pg_attrdef ON (   pg_attribute.attrelid = pg_attrdef.adrelid 
                                 AND pg_attribute.attnum = pg_attrdef.adnum)
   LEFT OUTER JOIN pg_description ON (   pg_description.objoid = pg_attribute.attrelid
                                     AND pg_description.objsubid = pg_attribute.attnum)
   WHERE attnum > 0
     AND (pg_description.classoid = (SELECT oid
                                     FROM pg_class
                                    WHERE relname = 'pg_class')
          OR pg_description.classoid IS NULL)
     AND attrelid = ?;
};


# - uses pg_class.oid
my $sql_Constraint = qq{
  SELECT substr(rcsrc, 2, length(rcsrc) - 2) as constraint_source
       , rcname as constraint_name
    FROM pg_relcheck
   WHERE rcrelid = ?;
};


my $sth_Tables = $dbh->prepare($sql_Tables);
my $sth_Foreign_Keys = $dbh->prepare($sql_Foreign_Keys);
my $sth_Primary_Keys = $dbh->prepare($sql_Primary_Keys);
my $sth_Columns = $dbh->prepare($sql_Columns);
my $sth_Constraint = $dbh->prepare($sql_Constraint);

my %structure;

# Main Loop
$sth_Tables->execute();
while (my $tables = $sth_Tables->fetchrow_hashref) {
  my $table_oid = $tables->{'oid'};
  my $table_name = $tables->{'tablename'};

  my $group;

  #print "$table_name\n";
  foreach my $ref (keys %StereoType) {

    if ($table_name =~ /$StereoType{$ref}/) {
      $group = $ref;

      goto EXPRESSIONFOUND; 
    }
  }
EXPRESSIONFOUND:

  if ($group eq '') {
    $group = $default_group;
  }

  $structure{$group}{$table_name}{'DESCRIPTION'} = $tables->{'table_description'};

  $sth_Constraint->execute($table_oid);
  while (my $cols = $sth_Constraint->fetchrow_hashref) {
    my $constraint_name = $cols->{'constraint_name'};

    $structure{$group}{$table_name}{'CONSTRAINT'}{$constraint_name} = $cols->{'constraint_source'};

#    print "        $constraint_name\n";
  }


  $sth_Columns->execute($table_oid);
  while (my $cols = $sth_Columns->fetchrow_hashref) {
    my $column_name = $cols->{'column_name'};
    $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'PRIMARY KEY'} = 0;
    $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'FK'} = '';
    $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'TYPE'} = $cols->{'column_type'};
    $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'NULL'} = $cols->{'column_null'};
    $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'DESCRIPTION'} = $cols->{'column_description'};
    $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'DEFAULT'} = $cols->{'column_default'};

    # Convert sequences to SERIAL type.
    if (  $showserials
       && $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'TYPE'} eq 'int4'
       && $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'DEFAULT'} =~ '^nextval\(.*?seq[\'"]*::text\)$'
       ) {

      $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'TYPE'} = 'serial';
      $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'DEFAULT'} = '';
    }

    if (  $showserials
       && $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'TYPE'} eq 'int8'
       && $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'DEFAULT'} =~ '^nextval\(.*?seq[\'"]*::text\)$'
       ) {

      $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'TYPE'} = 'serial8';
      $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'DEFAULT'} = '';
    }

#    print "        $table_name -> $column_name\n";
#    print $structure{$group}{$table_name}{'COLUMN'}{$column_name}{'TYPE'} ."\n\n";
  }

  $sth_Primary_Keys->execute($table_oid);
  while (my $pricols = $sth_Primary_Keys->fetchrow_hashref) {
    my $column_oid = $pricols->{'oid'};
    my $column_name = $pricols->{'column_name'};
    my $column_number = $pricols->{'index_count'};
    my $index_type = $pricols->{'index_type'};
    my $index_name = $pricols->{'index_name'};

    if ($column_number == 1) {

      $structure{$group}{$table_name}{'COLUMN'}{$column_name}{$index_type} = 1;
    } else {
      # Lets form a multikey index
      if (exists($structure{$group}{$table_name}{'CONSTRAINT'}{$index_name})) {
        my $match = substr($structure{$group}{$table_name}{'CONSTRAINT'}{$index_name}, 0, -1);

        $structure{$group}{$table_name}{'CONSTRAINT'}{$index_name} = $match . ", $column_name)";

      } else {
        $structure{$group}{$table_name}{'CONSTRAINT'}{$index_name} = "$index_type ($column_name)";
      }
    }

#    print "   PK	$index_type	$column_number	$table_name	$column_name\n";
  }


  $sth_Foreign_Keys->execute($table_oid);
  while (my $forcols = $sth_Foreign_Keys->fetchrow_hashref) {
    my $column_oid = $forcols->{'oid'};
    my $args = $forcols->{'args'};
    my $constraint_name = $forcols->{'constraint_name'};
    my $nargs = $forcols->{'number_args'};

    if ($nargs == 6) {
      my ( $keyname
         , $table
         , $ftable
         , $unspecified
         , $lcolumn_name
         , $fcolumn_name
         ) = split(/\000/, $args);

      $structure{$group}{$table_name}{'COLUMN'}{$lcolumn_name}{'FK'} = "$ftable";  #.$fcolumn_name";

      # print "   FK   $lcolumn_name -> $ftable.$fcolumn_name\n";
    } elsif (($nargs - 6) % 2 == 0) {
      my ( $keyname
         , $table
         , $ftable
         , $unspecified
         , $lcolumn_name
         , $fcolumn_name
         , @junk
         ) = split(/\000/, $args);

      my $key_cols = "$lcolumn_name";
      my $ref_cols = "$fcolumn_name";

      while ($lcolumn_name = pop(@junk) and $fcolumn_name = pop(@junk)) {

        $key_cols .= ", $lcolumn_name";
        $ref_cols .= ", $fcolumn_name";
      }

      $structure{$group}{$table_name}{'CONSTRAINT'}{$constraint_name} = "FOREIGN KEY ($key_cols) REFERENCES $ftable($ref_cols)";
    }
  }
}

if ($do_uml == 1) {
  &write_uml_structure(%structure);
}

if ($do_index == 1) {
  &write_index_structure(%structure);
}

if ($do_docbook == 1) {
  &write_docbook_structure(%structure);
}


#####################################
sub write_index_structure($structure) {
  sysopen(FH, $index_outputfile, O_WRONLY|O_EXCL|O_CREAT, 0644) or die "Can't open $index_outputfile: $!";

  print FH '<html><head><title>Index for '. $database .'</title></head><body>';

  ## Primary Index
  print FH '<a name="index"><h1>Index</h1><ul>';
  foreach my $group (sort keys %structure) {
    if ($group ne $default_group) {
      print FH '<li><a name="group_'. $group .'">'. $group .'</a></li>';
      print FH '<ul>';
    }

    foreach my $table (sort keys %{$structure{$group}}) {
      print FH '<li><a href="#table_'. $table .'">'. $table .'</a></li>';
    }
    if ($group ne $default_group) {
      print FH '</ul>';
    }
  }
  print FH '</ul>';

  ## Group Creation
  foreach my $group (sort keys %structure) {

    foreach my $table (sort keys %{$structure{$group}}) {
      print FH '<hr><h2>Table: ';

      if ($group ne $default_group) {
        print FH  '<a href="#group_'. $group .'">'. $group .'</a> - ';
      }

      print FH  '<a name="table_'. $table.'">'. $table .'</a></h2>
                <p>'. $structure{$group}{$table}{'DESCRIPTION'} .'</p>
                <table width="100%" cellspacing="0" cellpadding="3" border="1">
                <caption>';
      if ($group ne $default_group) {
        print FH $group .' - ';
      }
      print FH '"'. $table .'" Structure</caption>
                <tr bgcolor="#E0E0EE">
                <th>F-Key</th>
                <th>Name</th>
                <th>Type</th>
                <th>Description</th>
                </tr>';
      foreach my $column (sort keys %{$structure{$group}{$table}{'COLUMN'}})  {

        print FH '<tr>';

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'FK'} ne '') {

          my $fk_group;
          foreach my $fk_search_group (sort keys %structure) {
            foreach my $fk_search_table (sort keys %{$structure{$fk_search_group}}) {
              if ($fk_search_table eq $structure{$group}{$table}{'COLUMN'}{$column}{'FK'}) {
                $fk_group = $fk_search_group;

                # NOTE:  How do we get out of 2 loops quickly?
              }
            }
          }

          print FH '<td><a href="#table_'. $structure{$group}{$table}{'COLUMN'}{$column}{'FK'}
                 . '">';

          if ($fk_group ne $default_group) {
            print FH $fk_group .' -> ';
          }

          print FH $structure{$group}{$table}{'COLUMN'}{$column}{'FK'} .'</a>
                    </td>';
        } else {
          print FH '<td></td>';
        }


        print FH '<td>'. $column .'</td>
                  <td>'. $structure{$group}{$table}{'COLUMN'}{$column}{'TYPE'} .'</td><td>';

        my $marker_wasdata = 0;
        if ($structure{$group}{$table}{'COLUMN'}{$column}{'NULL'} ne '') {
          print FH '<i>'. $structure{$group}{$table}{'COLUMN'}{$column}{'NULL'};
          $marker_wasdata = 1;
        }

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'PRIMARY KEY'} == 1) {
          if ($marker_wasdata == 1) {
            print FH ' PRIMARY KEY ';
          } else {
            print FH '<i>PRIMARY KEY ';
            $marker_wasdata = 1;
          }
        }

        if (exists($structure{$group}{$table}{'COLUMN'}{$column}{'UNIQUE'})) {
          if ($marker_wasdata == 1) {
            print FH ' UNIQUE ';
          } else {
            print FH '<i>UNIQUE ';
            $marker_wasdata = 1;
          }
        }

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'} ne '') {
          if ($marker_wasdata == 1) {
            print FH ' default '. $structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'};
          } else {
            print FH '<i>default '. $structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'};
            $marker_wasdata = 1;
          }
        }

        if ($marker_wasdata == 1) {
          print FH '</i>';
        }

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'DESCRIPTION'} ne '') {
          if ($marker_wasdata == 1) {
            print FH '<br><br>';
          }
          print FH $structure{$group}{$table}{'COLUMN'}{$column}{'DESCRIPTION'};
        }

        print FH '</td></tr>';

      }
      print FH '</table>';


      # Constraint List
      my $constraint_marker = 0;
      foreach my $constraint (sort keys %{$structure{$group}{$table}{'CONSTRAINT'}})  {
        if ($constraint_marker == 0) {
          print FH '<br><table  width="100%" cellspacing="0" cellpadding="3" border="1">
                    <caption>';
                    
          if ($group ne $default_group) {
            print FH $group .' - ';
          }
          print FH '"'. $table .'" Constraints</caption>
                    <tr bgcolor="#E0E0EE">
                    <th>Name</th>
                    <th>Constraint</th>
                    </tr>';
          $constraint_marker = 1;
        }
        print FH '<tr><td>'. $constraint .'</td>
                      <td>'. $structure{$group}{$table}{'CONSTRAINT'}{$constraint} .'</td></tr>';
      }
      if ($constraint_marker == 1) {
        print FH '</table>';
      }

      # Foreign Key Discovery
      my $fk_marker = 0;
      foreach my $fk_group (sort keys %structure) {
        foreach my $fk_table (sort keys %{$structure{$fk_group}}) {
          foreach my $fk_column (sort keys %{$structure{$fk_group}{$fk_table}{'COLUMN'}})  {
            if ($structure{$fk_group}{$fk_table}{'COLUMN'}{$fk_column}{'FK'} eq $table) {
              if ($fk_marker == 0) {
                print FH '<p>Tables referencing this one via Foreign Key Constraints:<ul>';
                $fk_marker = 1;
              }
              print FH '<li><a href="#table_'. $fk_table .'">';
              if ($fk_group ne $default_group) {
                print FH $fk_group .' -> ';
              }
              print FH $fk_table .'</a></li>';
            }
          }
        }
      }

      if ($fk_marker == 1) {
        print FH '</ul></p>';
      }

      print FH '<a href="#index">Index</a>';

      if ($group ne $default_group) {
        print FH ' - <a href="#group_'. $group .'">StereoType '. $group .'</a>';
      }
    }
  }
  print FH '</ul>';

  print FH '</body></html>';
}


#####################################
sub write_uml_structure($structure) {

  sysopen(FH, $uml_outputfile, O_WRONLY|O_EXCL|O_CREAT, 0644) or die "Can't open $uml_outputfile: $!";

  print FH '<?xml version="1.0"?>
<dia:diagram xmlns:dia="http://www.lysator.liu.se/~alla/dia/">
  <dia:diagramdata>
    <dia:attribute name="background">
      <dia:color val="#ffffff"/>
    </dia:attribute>
    <dia:attribute name="paper">
      <dia:composite type="paper">
        <dia:attribute name="name">
          <dia:string>#A4#</dia:string>
        </dia:attribute>
        <dia:attribute name="tmargin">
          <dia:real val="2.8222"/>
        </dia:attribute>
        <dia:attribute name="bmargin">
          <dia:real val="2.8222"/>
        </dia:attribute>
        <dia:attribute name="lmargin">
          <dia:real val="2.8222"/>
        </dia:attribute>
        <dia:attribute name="rmargin">
          <dia:real val="2.8222"/>
        </dia:attribute>
        <dia:attribute name="is_portrait">
          <dia:boolean val="true"/>
        </dia:attribute>
        <dia:attribute name="scaling">
          <dia:real val="1"/>
        </dia:attribute>
        <dia:attribute name="fitto">
          <dia:boolean val="false"/>
        </dia:attribute>
      </dia:composite>
    </dia:attribute>
    <dia:attribute name="grid">
      <dia:composite type="grid">
        <dia:attribute name="width_x">
          <dia:real val="1"/>
        </dia:attribute>
        <dia:attribute name="width_y">
          <dia:real val="1"/>
        </dia:attribute>
        <dia:attribute name="visible_x">
          <dia:int val="1"/>
        </dia:attribute>
        <dia:attribute name="visible_y">
          <dia:int val="1"/>
        </dia:attribute>
      </dia:composite>
    </dia:attribute>
    <dia:attribute name="guides">
      <dia:composite type="guides">
        <dia:attribute name="hguides"/>
        <dia:attribute name="vguides"/>
      </dia:composite>
    </dia:attribute>
  </dia:diagramdata>
  <dia:layer name="Background" visible="true">
';

  my $id;
  my %tableids;

  foreach my $group (sort keys %structure) {

    if ($group ne $default_group) {
      # Don't group the individual tables.

      print FH '
      <dia:group>';
    }

    foreach my $table (sort keys %{$structure{$group}}) {

      $tableids{$table} = $id++;


      my $constraintlist = "";
      foreach my $constraint (sort keys %{$structure{$group}{$table}{'CONSTRAINT'}})  {

        $constraintlist .= '
        <dia:composite type="umloperation">
          <dia:attribute name="name">
            <dia:string>##</dia:string>
          </dia:attribute>
          <dia:attribute name="type">
            <dia:string/>
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
                <dia:string>'. xml_safe_chars('#'. $structure{$group}{$table}{'CONSTRAINT'}{$constraint} .'#') .'</dia:string>
              </dia:attribute>
              <dia:attribute name="type">
                <dia:string>##</dia:string>
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
      foreach my $column (sort keys %{$structure{$group}{$table}{'COLUMN'}})  {
        my $currentcolumn;

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'PRIMARY KEY'} == 1) {
          $currentcolumn .= "PK ";

        } else {
          $currentcolumn .= "   ";
        }

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'FK'} eq '') {
          $currentcolumn .= "   ";
        } else {
          $currentcolumn .= "FK ";
        }

        $currentcolumn .= "$column";
#       if ($structure{$group}{$table}{'COLUMN'}{$column}{'FK'} ne '') {
#         $currentcolumn .= "  -> ". $structure{$group}{$table}{'COLUMN'}{$column}{'FK'};
#       }

        $structure{$group}{$table}{'COLUMN'}{$column}{'TYPE'} =~ tr/a-z/A-Z/;

        $columnlist .= '
        <dia:composite type="umlattribute">
          <dia:attribute name="name">
            <dia:string>'. xml_safe_chars('#'. $currentcolumn .'#') .'</dia:string>
          </dia:attribute>
          <dia:attribute name="type">
            <dia:string>'. xml_safe_chars('#'. $structure{$group}{$table}{'COLUMN'}{$column}{'TYPE'} .'#') .'</dia:string>
          </dia:attribute>';
        if ($structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'} eq '') {
          $columnlist .= '
          <dia:attribute name="value">
            <dia:string/>
          </dia:attribute>';
        } else {
          $columnlist .= '
          <dia:attribute name="value">
            <dia:string>'. xml_safe_chars('#'. $structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'} .'#') .'</dia:string>
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
    <dia:object type="UML - Class" version="0" id="O'. $tableids{$table} .'">
      <dia:attribute name="obj_pos">
        <dia:point val="7.3,1.85"/>
      </dia:attribute>
      <dia:attribute name="obj_bb">
        <dia:rectangle val="7.25,0.9;27.542,5.7"/>
      </dia:attribute>
      <dia:attribute name="elem_corner">
        <dia:point val="7.3,1.85"/>
      </dia:attribute>
      <dia:attribute name="elem_width">
        <dia:real val="20.192"/>
      </dia:attribute>
      <dia:attribute name="elem_height">
        <dia:real val="3.2"/>
      </dia:attribute>
      <dia:attribute name="name">
        <dia:string>'. xml_safe_chars('#'. $table .'#'). '</dia:string>
      </dia:attribute>
      <dia:attribute name="stereotype">
        <dia:string>';

          if ($group ne $default_group) {
            print FH xml_safe_chars('#'. $group .'#');
          }

          print FH '</dia:string>
      </dia:attribute>
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
      <dia:attribute name="foreground_color">
        <dia:color val="#000000"/>
      </dia:attribute>
      <dia:attribute name="background_color">
        <dia:color val="#ffffff"/>
      </dia:attribute>
      <dia:attribute name="attributes">'. 
          $columnlist 
      .'</dia:attribute>';

      if ($constraintlist eq '') {
        print FH '
      <dia:attribute name="visible_operations">
        <dia:boolean val="false"/>
      </dia:attribute>
      <dia:attribute name="operations"/>';
      } else {
        print FH '
      <dia:attribute name="visible_operations">
        <dia:boolean val="true"/>
      </dia:attribute>
      <dia:attribute name="operations">'. 
          $constraintlist 
      .'
      </dia:attribute>';
      }

      print FH '
      <dia:attribute name="template">
        <dia:boolean val="false"/>
      </dia:attribute>
      <dia:attribute name="templates"/>
    </dia:object>';
    }

    if ($group ne $default_group) {
      print FH '
      </dia:group>';
    }
  }

  foreach my $group (sort keys %structure) {

    foreach my $table (sort keys %{$structure{$group}}) {

      foreach my $column (sort keys %{$structure{$group}{$table}{'COLUMN'}})  {

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'FK'} ne '') {

          print FH '
      <dia:object type="UML - Generalization" version="0" id="O'. $id++ .'">
      <dia:attribute name="obj_pos">
        <dia:point val="17.9784,8.2"/>
      </dia:attribute>
      <dia:attribute name="obj_bb">
        <dia:rectangle val="12.998,3.9;18.8284,8.2"/>
      </dia:attribute>
      <dia:attribute name="orth_points">
        <dia:point val="17.9784,8.2"/>
        <dia:point val="17.9784,4.7"/>
        <dia:point val="13.048,4.7"/>
        <dia:point val="13.048,4.7"/>
      </dia:attribute>
      <dia:attribute name="orth_orient">
        <dia:enum val="1"/>
        <dia:enum val="0"/>
        <dia:enum val="1"/>
      </dia:attribute>
      <dia:attribute name="name">
        <dia:string>'. xml_safe_chars('#'. $column .'#') .'</dia:string>
      </dia:attribute>
      <dia:attribute name="stereotype">
        <dia:string>';

          if ($group ne $default_group) {
            print FH xml_safe_chars('#'. $structure{$group}{$table}{'COLUMN'}{$column}{'FK'} .'#');
          }

          print FH '</dia:string>
      </dia:attribute>
      <dia:connections>
        <dia:connection handle="0" to="O'. $tableids{$table} .'" connection="2"/>
        <dia:connection handle="1" to="O'. $tableids{$structure{$group}{$table}{'COLUMN'}{$column}{'FK'}} .'" connection="7"/>
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
sub write_docbook_structure($structure) {

  sysopen(FH, $docbook_outputfile, O_WRONLY|O_EXCL|O_CREAT, 0644) or die "Can't open $docbook_outputfile: $!";

  print FH '<appendix id="docguide" xreflabel="Schema '. $database .'"><title>'. $database .' Model</title>';

  ## Group Creation
  foreach my $group (sort keys %structure) {

    foreach my $table (sort keys %{$structure{$group}}) {

      # Section Identifier
      print FH '<sect1 id="'. sgml_safe_id($database) .'-table-'.  sgml_safe_id($table)
               .'" xreflabel="Table ';

      if ($group ne $default_group) {
        print FH $group .' - ';
      }

      print FH $table .'">';


      # Section Title
      print FH '<title>';

      if ($group ne $default_group) {
        print FH  $group .' - ';
      }

      print FH $table .'</title>';


      # Relation Description
      print FH '<para>'. $structure{$group}{$table}{'DESCRIPTION'} .'</para>';

      # Table structure
      print FH '<table><title>';

      if ($group ne $default_group) {
        print FH $group .' - ';
      }

      print FH  'Structure of <structname>'. $table .'</structname></title><tgroup cols="4">';

      print FH '<thead><row>';
      print FH '<entry>Name</entry>';
      print FH '<entry>Type</entry>';
      print FH '<entry>References</entry>';
      print FH '<entry>Description</entry>';
      print FH '</row></thead>';
      print FH '<tbody>';

      foreach my $column (sort keys %{$structure{$group}{$table}{'COLUMN'}})  {

        print FH '<row>';

        print FH '<entry>'. $column .'</entry>
                  <entry>'. $structure{$group}{$table}{'COLUMN'}{$column}{'TYPE'} .'</entry>';

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'FK'} ne '') {

          my $fk_group;
          foreach my $fk_search_group (sort keys %structure) {
            foreach my $fk_search_table (sort keys %{$structure{$fk_search_group}}) {
              if ($fk_search_table eq $structure{$group}{$table}{'COLUMN'}{$column}{'FK'}) {
                $fk_group = $fk_search_group;

                goto ENDLOOP # Get me out of here...
              }
            }
          }
ENDLOOP:

          print FH '<entry><xref linkend="'. sgml_safe_id($database) .'-table-'. 
                    sgml_safe_id($structure{$group}{$table}{'COLUMN'}{$column}{'FK'}) . '"></entry>';

        } else {
          print FH '<entry></entry>';
        }

        print FH '<entry>';


        my $liststarted = 0;

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'NULL'} ne '') {
          if ($liststarted == 0) {
            print FH '<simplelist>';
            $liststarted = 1;
          }
          print FH '<member>'. $structure{$group}{$table}{'COLUMN'}{$column}{'NULL'} .'</member>';
        }

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'PRIMARY KEY'} == 1) {
          if ($liststarted == 0) {
            print FH '<simplelist>';
            $liststarted = 1;
          }
          print FH '<member>PRIMARY KEY</member>';
        }

        if (exists($structure{$group}{$table}{'COLUMN'}{$column}{'UNIQUE'})) {
          if ($liststarted == 0) {
            print FH '<simplelist>';
            $liststarted = 1;
          }
          print FH '<member>UNIQUE</member>';
        }

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'} ne '') {
          if ($liststarted == 0) {
            print FH '<simplelist>';
            $liststarted = 1;
          }
          print FH '<member>DEFAULT '. $structure{$group}{$table}{'COLUMN'}{$column}{'DEFAULT'}
                 . '</member>';
        }
        
        if ($liststarted != 0) {
          print FH '</simplelist>';
        }

        if ($structure{$group}{$table}{'COLUMN'}{$column}{'DESCRIPTION'} ne '') {
          print FH '<para>'. $structure{$group}{$table}{'COLUMN'}{$column}{'DESCRIPTION'} .'</para>';
        }

        print FH '</entry>';

        print FH '</row>';
      }
      print FH '</tbody></tgroup></table>';


      # Constraint List
      my $constraintstart = 0;
      foreach my $constraint (sort keys %{$structure{$group}{$table}{'CONSTRAINT'}})  {
        if ($constraintstart == 0) {
          print FH '<sect2><title>Constraints of table ';

          if ($group ne $default_group) {
            print FH $group .' - ';
          }
          print FH $table .'.</title><para>'; 

          print FH '<simplelist>';

          $constraintstart = 1;
        }
        print FH '<member>'. $structure{$group}{$table}{'CONSTRAINT'}{$constraint} .'</member>';
      }
      if ($constraintstart != 0) {
        print FH '</simplelist></para></sect2>';
      }

      # Foreign Key Discovery
      my $fkinserted = 0;
      foreach my $fk_group (sort keys %structure) {
        foreach my $fk_table (sort keys %{$structure{$fk_group}}) {
          foreach my $fk_column (sort keys %{$structure{$fk_group}{$fk_table}{'COLUMN'}})  {
            if ($structure{$fk_group}{$fk_table}{'COLUMN'}{$fk_column}{'FK'} eq $table) {
              if ($fkinserted == 0) {
                print FH '<sect2><title>Foreign Key Constrained</title>
                          <para>Tables referencing '. $table .' via Foreign Key Constraints</para><para>';

                print FH '<simplelist>';

                $fkinserted = 1;
              }

              print FH '<member><xref linkend="'. sgml_safe_id($database) .'-table-'. 
                       sgml_safe_id($fk_table) .'"></member>';
            }
          }
        }
      }
      if ($fkinserted != 0) {
        print FH '</simplelist></para></sect2>';
      }

      print FH '</sect1>';
    }
  }
  print FH '</appendix>';

}



# Convert various characters to their 'XML Safe' version
sub xml_safe_chars {
  my $string = shift;

  $string =~ s/&(?!(amp|lt|gr|apos|quot);)/&amp;/g;
  $string =~ s/</&lt;/g;
  $string =~ s/>/&gt;/g;
  $string =~ s/'/&apos;/g;
  $string =~ s/"/&quot;/g;

  return ($string);
}

# Safe SGML ID Character replacement
sub sgml_safe_id {
  my $string = shift;

  $string =~ s/_/-/g;
  
  return($string);
}


sub usage {
      print <<USAGE
Usage:
  postgres_to_dia.pl [options] [dbname [username]]

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

  -s              Converts columns of int4 type with a sequence by default to SERIAL type
  -S              Ignores SERIAL type entirely.  (No conversions).

USAGE
;
      exit 0;
}
