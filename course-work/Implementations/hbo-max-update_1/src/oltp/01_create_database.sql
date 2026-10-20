/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    01_create_database.sql
   Purpose: Drop and recreate HBOMaxOLTP, then create the five business schemas
            plus an audit schema used by triggers.
   Target:  Microsoft SQL Server 2019+

   WARNING: this script DROPS the database. Do not run it against a database
            whose data you want to keep.
   ============================================================================= */

USE master;
GO

IF DB_ID('HBOMaxOLTP') IS NOT NULL
BEGIN
    ALTER DATABASE HBOMaxOLTP SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HBOMaxOLTP;
END
GO

CREATE DATABASE HBOMaxOLTP;
GO

ALTER DATABASE HBOMaxOLTP SET RECOVERY SIMPLE;
ALTER DATABASE HBOMaxOLTP SET READ_COMMITTED_SNAPSHOT ON;
GO

USE HBOMaxOLTP;
GO

/* ----- Business schemas ------------------------------------------------- */
IF SCHEMA_ID('geo')   IS NULL EXEC('CREATE SCHEMA geo');
IF SCHEMA_ID('acct')  IS NULL EXEC('CREATE SCHEMA acct');
IF SCHEMA_ID('cat')   IS NULL EXEC('CREATE SCHEMA cat');
IF SCHEMA_ID('play')  IS NULL EXEC('CREATE SCHEMA play');
IF SCHEMA_ID('bill')  IS NULL EXEC('CREATE SCHEMA bill');
IF SCHEMA_ID('audit') IS NULL EXEC('CREATE SCHEMA audit');
GO

PRINT 'HBOMaxOLTP created with schemas: geo, acct, cat, play, bill, audit.';
GO
