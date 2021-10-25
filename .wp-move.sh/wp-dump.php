<?php
// quick modification of a ExecDevOps script - https://github.com/ExecDevOps/wp2zip

// Wordpress backup to .ZIP including MySQL dump

// Upload script to Wordpress root directory, i.e. where wp-config.php resides. It reads database connection settings from wp-config.php and dumps the MySQL database to an .sql file. It then creates a compressed .zip archive of all Wordpress files/dirs and triggers the browser to download .zip archive to the caller's computer.

// N.B. the script does not encrypt the .zip nor does it delete the generated .sql or .zip files making them available for anyone to download should they know the name of the files. Also, there is no access control which means that anyone can call the script. Additional work needs to be done in order to eliminate these issues.
	ini_set( "max_execution_time", 600     );
	ini_set( "memory_limit",       "1024M" );


	// Sanitize incoming data
	$s_error  = "";
	$s_server = filter_input( INPUT_SERVER, "HTTP_HOST", FILTER_SANITIZE_STRING, FILTER_FLAG_STRIP_LOW | FILTER_FLAG_STRIP_HIGH );
	$s_src    = filter_input( INPUT_GET,    "s_src",     FILTER_SANITIZE_STRING, FILTER_FLAG_STRIP_LOW | FILTER_FLAG_STRIP_HIGH );


	// Presume current directory as source if no directory containing Wordpress was given
	if( !$s_src )
	{
		$s_src = "./";
	}

	// Add today's date to destination .ZIP filename
	$s_dst = $s_src . "/" . $s_server . "_" . date( "Y-m-d" );


	// Make sure all prerequisites are satisfied
	if( !is_dir( $s_src ) )
	{
		print "Source " . $s_src . " does not exist.";
		exit;
	}

	if( ( include $s_src . "wp-config.php" ) == FALSE )
	{
		print "Wordress config file not found.";
		exit;
	}

	if( DB_HOST == ""  ||  DB_USER == ""  ||  DB_PASSWORD == ""  ||  DB_NAME == "" )
	{
		print "Database connection information could not be read from wp-config.php.";
		exit;
	}

   
    // header('Content-Encoding: UTF-8');
    header("Content-type: application/sql");
    header("Cache-Control: must-revalidate, post-check=0, pre-check=0");
    header('Content-Description: File Transfer');
    header("Content-Disposition: attachment; filename=dump.sql");
    header("Expires: 0");
    header("Pragma: public");

            // echo "\xEF\xBB\xBF"; // UTF-8 BOM
            	// Create database dump
	if( !fn_mysql_dump( DB_HOST, DB_USER, DB_PASSWORD, DB_NAME, $s_dst . ".sql" ) )
	{
		print $s_error;
		exit;
	}

	exit;


	// Creates a MySQL dumpfile containing full SQL statements to rebuild all tables with data
	function fn_mysql_dump( $s_host, $s_user, $s_pass, $s_db, $s_dst )
	{
		global $s_error;


		set_time_limit(3000);


		// Create dumpfile
        // $fp = fopen( $s_dst, "wb" );
        $fp = fopen('php://output', 'wb');
		if( !$fp )
		{
			$s_error = "Can not create .sql file for MySQL dump.";
			return false;
		}

		// Connect to MySQL
		$mysqli = new mysqli( $s_host, $s_user, $s_pass, $s_db );
		if( $mysqli->connect_error )
		{
			$s_error =  "MySQL connect error (" . $mysqli->connect_errno . ") " . $mysqli->connect_error;
			return false;
		}


		$mysqli->select_db( $s_db );
		$mysqli->query( "SET NAMES 'utf8'" );


		// Start dump with mumbo-jumbo
		$s_sql  = "SET SQL_MODE = \"NO_AUTO_VALUE_ON_ZERO\";\r\n";
		$s_sql .= "SET time_zone = \"+00:00\";\r\n";
		$s_sql .= "\r\n";
		$s_sql .= "\r\n";
		$s_sql .= "/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;\r\n";
		$s_sql .= "/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;\r\n";
		$s_sql .= "/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;\r\n";
		$s_sql .= "/*!40101 SET NAMES utf8 */;\r\n";
		$s_sql .= "--\r\n";
		$s_sql .= "-- Database: " . $s_db . "\r\n";
		$s_sql .= "--\r\n";
		$s_sql .= "\r\n";
		$s_sql .= "\r\n";
		fputs( $fp, $s_sql, strlen( $s_sql ) );


		// Loop through all tables in the database
		$result_tables = $mysqli->query( "SHOW TABLES" );
		while( $row = $result_tables->fetch_row() )
		{
			$s_table = $row[0];


			// Write table creation statement
			$result   = $mysqli->query( "SHOW CREATE TABLE " . $s_table );
			$a_create = $result->fetch_row();

			$s_sql  = str_ireplace( array( "CREATE TABLE", "\n", "`" ), array( "CREATE TABLE IF NOT EXISTS", "\r\n", "" ), $a_create[1] ) . ";\r\n";
			$s_sql .= "\r\n";
			fputs( $fp, $s_sql, strlen( $s_sql ) );


			// Fetch all rows in table
			$result   = $mysqli->query( "SELECT * FROM " . $s_table );

			$i_rows   = $result->num_rows;
			$i_fields = $result->field_count;
			$a_fields = $result->fetch_fields();


			// Build statement for table insert
			$s_head = "INSERT INTO " . $s_table . " (";

			for( $i = 0; $i < $i_fields; $i++ )
			{
				$s_head .= $a_fields[$i]->name;

				if( $i < $i_fields - 1 )
				{
					$s_head .= ", ";
				}
			}

			$s_head .= ") VALUES\r\n";


			// Loop through all rows in table
			$i_row = 0;

			while( $row = $result->fetch_row() )
			{
				// Write table insert first and then every 100 rows
				if( $i_row == 0  ||  $i_row % 100 == 0 )
				{
					$s_sql  = "\r\n";
					$s_sql .= $s_head;
					fputs( $fp, $s_sql, strlen( $s_sql ) );
				}


				// Build table row with all columns and data
				$s_sql = "(";

				for( $j = 0; $j < $i_fields; $j++ )
				{
					$s_sql .= '"' . str_replace( "\n", "\\n", $mysqli->real_escape_string( $row[$j] ) ) . '"';

					if( $j < ( $i_fields - 1 ) )
					{
						$s_sql .= ',';
					}
				}

				// End table row nicely
				if( ( ( $i_row + 1 ) % 100 == 0  &&  $i_row != 0 )  ||  ( $i_row + 1 ) == $i_rows )
				{
					$s_sql .= ");\r\n";
				}
				else
				{
					$s_sql .= "),\r\n";
				}

				// Write table row to file
				fputs( $fp, $s_sql, strlen( $s_sql ) );


				$i_row++;
			}


			// Write table end to file
			$s_sql  = "\r\n";
			$s_sql .= "\r\n";
			$s_sql .= "\r\n";
			fputs( $fp, $s_sql, strlen( $s_sql ) );
		}


		// Write database end and close file
		$s_sql  = "\r\n";
		$s_sql .= "\r\n";
		$s_sql .= "/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;\r\n";
		$s_sql .= "/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;\r\n";
		$s_sql .= "/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;\r\n";
		fputs( $fp, $s_sql, strlen( $s_sql ) );

		fclose( $fp );


		return true;
	}
?>