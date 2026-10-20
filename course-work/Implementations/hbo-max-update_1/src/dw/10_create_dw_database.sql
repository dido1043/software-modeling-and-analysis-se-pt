/* =============================================================================
   HBO Max - Software Modeling and Analysis course work
   File:    10_create_dw_database.sql
   Purpose: Drop and recreate HBOMaxDW, and create the dw (presentation) and
            etl (staging / orchestration) schemas.
   Target:  Microsoft SQL Server 2019+

   WARNING: this script DROPS the database. Do not run it against a database
            whose data you want to keep. HBOMaxOLTP must exist on the SAME
            instance - the ETL procedures use three-part names.
   ============================================================================= */

USE master;
GO

IF DB_ID('HBOMaxDW') IS NOT NULL
BEGIN
    ALTER DATABASE HBOMaxDW SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HBOMaxDW;
END
GO

CREATE DATABASE HBOMaxDW;
GO

ALTER DATABASE HBOMaxDW SET RECOVERY SIMPLE;
GO

USE HBOMaxDW;
GO

IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
GO

PRINT 'HBOMaxDW created with schemas: dw, etl.';
GO
