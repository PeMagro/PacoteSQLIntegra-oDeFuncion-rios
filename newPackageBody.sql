create or replace PACKAGE BODY AM_41_UKG_EMPLOYEE_TO_HCM_PKG AS

    I_P_DOC_TYPE CONSTANT VARCHAR2(100) := 'INT41';

    PROCEDURE I_41_UKG_EMPLOYEE_LOAD_PRC (
            I_P_OIC_ID          IN VARCHAR2,
            I_P_STARTER_ID      IN VARCHAR2,
            I_P_FILE_NAME       IN VARCHAR2,
            I_P_CONTENT         IN CLOB,
            I_P_SOURCE_SYSTEM   IN VARCHAR2,
            I_P_DOC_TYPE        IN VARCHAR2,
            O_P_RESPONSE        OUT CLOB,
            O_P_STATUS          OUT VARCHAR2
        )
        IS
            L_V_CHILD_PROCEDURE_STATUS VARCHAR2(32);
            L_V_CHILD_PROCEDURE_RESPONSE CLOB;
            l_v_PAYLOAD_ID VARCHAR2(64);
        BEGIN
                DBMS_OUTPUT.PUT_LINE('I_41_UKG_EMPLOYEE_LOAD_PRC Procedure Started');

                INSERT INTO AM_INBOUND_PAYLOADS_RAW (
                        FILE_NAME       
                        ,DOC_TYPE       
                        ,FILE_BATCH     
                        ,FILE_SEQUENCE  
                        ,SOURCE_SYSTEM  
                        ,PAYLOAD_DATA
                        ,OIC_INSTANCE_ID
                        ,STARTER_INSTANCE_ID
                    ) VALUES (
                        I_P_FILE_NAME        -- FILE_NAME       
                        ,I_P_DOC_TYPE        -- ,DOC_TYPE       
                        ,NULL                -- ,FILE_BATCH     
                        ,NULL                -- ,FILE_SEQUENCE  
                        ,I_P_SOURCE_SYSTEM   -- ,SOURCE_SYSTEM  
                        ,I_P_CONTENT         -- ,PAYLOAD_DATA
                        ,I_P_OIC_ID          -- ,OIC_INSTANCE_ID
                        ,I_P_STARTER_ID      -- ,STARTER_INSTANCE_ID
                    )
                RETURNING PAYLOAD_REC_ID INTO l_v_PAYLOAD_ID;

                COMMIT;
                O_P_RESPONSE := O_P_RESPONSE || '    Payload data loaded into AM_INBOUND_PAYLOADS_RAW' || CHR(10) || CHR(10);
                O_P_RESPONSE := O_P_RESPONSE || '    Invoking I_41_UKG_EMPLOYEE_PARSE_PRC Procedure' || CHR(10) || CHR(10);
                I_41_UKG_EMPLOYEE_PARSE_PRC(
                    I_P_OIC_ID
                    ,I_P_STARTER_ID
                    ,l_v_PAYLOAD_ID
                    ,I_P_DOC_TYPE
                    ,L_V_CHILD_PROCEDURE_STATUS
                    ,L_V_CHILD_PROCEDURE_RESPONSE
                );
                O_P_RESPONSE := O_P_RESPONSE || L_V_CHILD_PROCEDURE_RESPONSE || CHR(10) || CHR(10);
                O_P_RESPONSE := O_P_RESPONSE || 'I_P_DOC_TYPE VALUE:' || I_P_DOC_TYPE || CHR(10) || CHR(10);      --! TEST PRINT
                O_P_RESPONSE :=  '    I_41_UKG_EMPLOYEE_PARSE_PRC Procedure completed' || CHR(10) || CHR(10);

                O_P_STATUS := L_V_CHILD_PROCEDURE_STATUS;
            O_P_RESPONSE := O_P_RESPONSE || 'I_41_UKG_EMPLOYEE_LOAD_PRC Procedure completed' || CHR(10) || CHR(10);
        EXCEPTION
            WHEN OTHERS THEN
                O_P_STATUS      := 'ERROR';
                O_P_RESPONSE    := O_P_RESPONSE || CHR(10) || 'Error: ' || SQLCODE || CHR(10) || SQLERRM || CHR(10) || 'Trace: ' || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
    END I_41_UKG_EMPLOYEE_LOAD_PRC;

    PROCEDURE I_41_UKG_EMPLOYEE_PARSE_PRC (
            I_P_OIC_ID              IN VARCHAR2 DEFAULT NULL,
            p_starter_instance_id   IN VARCHAR2 DEFAULT NULL,
            p_payload_rec_id        IN NUMBER,
            I_P_DOC_TYPE            IN VARCHAR2,
            O_P_STATUS              OUT VARCHAR2,
            O_P_RESPONSE            OUT CLOB
        ) AS
            TYPE t_id_tab IS TABLE OF I_41_UKG_EMPLOYEES_STG.EMPLOYEE_REC_ID%TYPE;
            l_employee_rec_ids      t_id_tab;
            --l_employee_rec_id         I_41_UKG_EMPLOYEES_STG.EMPLOYEE_REC_ID%TYPE;
            l_employee_rec_id       VARCHAR2(64 CHAR);--I_41_UKG_PERSON_STG.PERSON_REC_ID%TYPE;
            l_payload_rec_row       AM_INBOUND_PAYLOADS_RAW%ROWTYPE;
            l_source_doc_id         VARCHAR2(64 CHAR);
            l_employee_counter      NUMBER := 0;
            l_person_counter        NUMBER := 0;
            e_resource_busy         EXCEPTION;
            PRAGMA EXCEPTION_INIT(e_resource_busy, -54);
            L_ERROR_CODE            VARCHAR2(64 CHAR);
            L_ERROR_MESSAGE         VARCHAR2(4000);
        BEGIN

            SELECT *
            INTO l_payload_rec_row
            FROM am_inbound_payloads_raw
            WHERE payload_rec_id = p_payload_rec_id
            AND doc_type         = I_P_DOC_TYPE
            AND processed_flag   = 'N'
            FOR UPDATE NOWAIT;

            UPDATE am_inbound_payloads_raw
            SET processed_flag      = 'P',
                last_update_date    = SYSDATE,
                last_update_by_name = 'OIC_INTEGRATION',
                error_code          = NULL,
                error_message       = NULL
            WHERE payload_rec_id = p_payload_rec_id;

            --------------
            -- EMPLOYEE --
            --------------

            IF l_payload_rec_row.payload_data IS NULL THEN
                L_ERROR_MESSAGE := 'PAYLOAD_DATA is NULL for PAYLOAD_REC_ID='||  l_payload_rec_row.payload_rec_id  || ' / File_name  =  "'|| l_payload_rec_row.file_name ||'"';
                RAISE_APPLICATION_ERROR(-20001, L_ERROR_MESSAGE);
            END IF;

            IF JSON_EXISTS(l_payload_rec_row.payload_data, '$[0]') AND I_P_DOC_TYPE = 'INT41E' THEN

                FOR emp IN (
                    SELECT employee_json
                    FROM JSON_TABLE(
                            l_payload_rec_row.payload_data FORMAT JSON,
                            '$[*]'
                            COLUMNS (
                                employee_json CLOB FORMAT JSON PATH '$'
                            )
                        )
                ) LOOP
                    l_employee_counter := l_employee_counter + 1;

                    l_source_doc_id := JSON_VALUE(emp.employee_json, '$."id"' RETURNING VARCHAR2(64) NULL ON ERROR);

                    IF NOT JSON_EXISTS(emp.employee_json, '$."EmployeeNumber"') THEN
                        RAISE_APPLICATION_ERROR(
                            -20003,
                            'Missing EmployeeNumber in one array element. payload_rec_id=' || p_payload_rec_id
                        );
                    END IF;

                    INSERT INTO I_41_UKG_EMPLOYEES_STG
                    (
                        PAYLOAD_REC_ID
                        ,FILE_NAME
                        ,SOURCE_DOC_ID
                        ,EMPLOYEE_ID
                        ,EMPLOYEE_NUMBER
                        ,HIRE_DATE
                        ,REHIRE_DATE --Original Hire Date
                        ,TERMINATION_DATE
                        ,JOB_CODE
                        ,DEPARTMENT_CODE
                        ,COMPANY_CODE_LEGAL_EMPLOYER
                        ,WORKER_TYPE
                        ,ACTION_CODE
                        ,BUSINESS_UNIT_NAME
                        ,DEFAULT_EXPENSE_ACCOUNT
                        ,MANAGER_ASSIGNMENT_NUMBER
                        ,OK_TO_REHIRE
                        ,EMPLOYEE_CHANGE
                        ,START_DATE
                        ,ASSIGNMENT_DATE
                        ,DATE_TIME_CHANGED
                        ,CREATED_BY_NAME
                        ,LAST_UPDATE_BY_NAME
                        ,STARTER_INSTANCE_ID
                        ,OIC_INSTANCE_ID
                    ) VALUES (
                        p_payload_rec_id
                        ,l_payload_rec_row.file_name
                        ,l_source_doc_id
                        ,JSON_VALUE(emp.employee_json, '$.EmployeeId' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.EmployeeNumber' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.HireDate' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.OriginalHireDate' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.TerminationDate' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.JobCode' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.DepartmentName' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.CompanyCodeLegalEmployer' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.WorkerType' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.ActionCode' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.BusinessUnitName' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.DefaultExpenseAccount' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.ManagerAssignmentNumber' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.okToRehire' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.jobChangeReasonCode' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.statusStartDate' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.assignmentDate' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(emp.employee_json, '$.dateTimeChanged' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,'OIC_INTEGRATION'
                        ,'OIC_INTEGRATION'
                        ,NVL(p_starter_instance_id, l_payload_rec_row.starter_instance_id)
                        ,NVL(I_P_OIC_ID, l_payload_rec_row.oic_instance_id)
                    );

                END LOOP; -- employee
            END IF;

            ------------
            -- PERSON --
            ------------

            IF JSON_EXISTS(l_payload_rec_row.payload_data, '$[0]') AND I_P_DOC_TYPE = 'INT41P' THEN

                FOR prs IN (
                    SELECT person_json
                    FROM JSON_TABLE(
                            l_payload_rec_row.payload_data FORMAT JSON,
                            '$[*]'
                            COLUMNS (
                                person_json CLOB FORMAT JSON PATH '$'
                            )
                        )
                ) LOOP
                    l_person_counter := l_person_counter + 1;

                    l_source_doc_id := JSON_VALUE(prs.person_json, '$."id"' RETURNING VARCHAR2(64) NULL ON ERROR);

                    IF NOT JSON_EXISTS(prs.person_json, '$."EmployeeId"') THEN
                        RAISE_APPLICATION_ERROR(
                            -20003,
                            'Missing EmployeeId in one array element. payload_rec_id=' || p_payload_rec_id
                        );
                    END IF;

                    INSERT INTO I_41_UKG_PERSON_STG 
                    (
                        PAYLOAD_REC_ID
                        ,FILE_NAME
                        ,SOURCE_DOC_ID  
                        ,EMPLOYEE_ID
                        ,FIRST_NAME
                        ,LAST_NAME
                        ,KNOWN_AS
                        ,SUFFIX
                        ,DATE_OF_BIRTH
                        ,EMAIL_ADDRESS
                        ,NATIONAL_ID
                        ,HOME_ADRESS_COUNTRY
                        ,DATE_TIME_CHANGED
                        ,CREATED_BY_NAME
                        ,LAST_UPDATE_BY_NAME
                        ,STARTER_INSTANCE_ID
                        ,OIC_INSTANCE_ID
                    ) VALUES (
                        p_payload_rec_id
                        ,l_payload_rec_row.file_name
                        ,l_source_doc_id
                        ,JSON_VALUE(prs.person_json, '$.EmployeeId' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(prs.person_json, '$.FirstName' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(prs.person_json, '$.LastName' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(prs.person_json, '$.KnownAs' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(prs.person_json, '$.Suffix' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(prs.person_json, '$.DateOfBirth' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(prs.person_json, '$.EmailAddress' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(prs.person_json, '$.NationalIdentifier' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(prs.person_json, '$.addressCountry' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,JSON_VALUE(prs.person_json, '$.dateTimeChanged' RETURNING VARCHAR2(400) NULL ON ERROR)
                        ,'OIC_INTEGRATION'
                        ,'OIC_INTEGRATION'
                        ,NVL(p_starter_instance_id, l_payload_rec_row.starter_instance_id)
                        ,NVL(I_P_OIC_ID, l_payload_rec_row.oic_instance_id)
                    );

                END LOOP; -- person
            END IF;

            -- Updating the EMPLOYEE_REC_ID in Person table

            /*FOR i IN 1 .. l_employee_rec_ids.COUNT LOOP
                l_employee_rec_id := TO_CHAR(l_employee_rec_ids(i));

                UPDATE I_41_UKG_PERSON_STG
                SET EMPLOYEE_REC_ID = l_employee_rec_id,
                    last_update_date    = SYSDATE,
                    last_update_by_name = 'OIC_INTEGRATION'
                WHERE EMPLOYEE_ID = (SELECT EMPLOYEE_ID FROM I_41_UKG_EMPLOYEES_STG WHERE EMPLOYEE_REC_ID = l_employee_rec_id);
            END LOOP;*/

            /*IF NOT JSON_EXISTS(l_payload_rec_row.payload_data, '$.employee') THEN
                L_ERROR_MESSAGE := 'Invalid JSON for PAYLOAD_REC_ID='||  l_payload_rec_row.payload_rec_id  || ' / File_name  =  "'|| l_payload_rec_row.file_name ||'"';
                RAISE_APPLICATION_ERROR(-20002, L_ERROR_MESSAGE);
            END IF;

            l_source_doc_id := JSON_VALUE(  l_payload_rec_row.payload_data,  '$.ukg_employee_id'  RETURNING VARCHAR2(64)  NULL ON ERROR  );*/

            /*INSERT INTO I_41_UKG_EMPLOYEES_STG
                (
                    PAYLOAD_REC_ID
                    ,FILE_NAME
                    ,SOURCE_DOC_ID  
                    ,EMPLOYEE_ID
                    ,EMPLOYEE_NUMBER
                    ,HIRE_DATE
                    ,TERMINATION_DATE
                    ,JOB_CODE
                    ,DEPARTMENT_CODE
                    ,LOCATION_CODE
                    ,COMPANY_CODE_LEGAL_EMPLOYER
                    ,WORKER_TYPE
                    ,DATE_TIME_CHANGED
                    ,CREATED_BY_NAME
                    ,LAST_UPDATE_BY_NAME
  'INTEGRATIONS'IC_INSTANCE_ID
                ) VALUES (
                    l_payload_rec_row.payload_rec_id
                    ,l_payload_rec_row.file_name
                    ,l_source_doc_id
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.EmployeeId' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.EmployeeNumber' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.HireDate' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.TerminationDate' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.JobCode' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.DepartmentCode' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.LocationCode' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.CompanyCodeLegalEmployer' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.EmployerType' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.dateTimeChanged' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,'OIC_INTEGRATION'
                    ,'OIC_INTEGRATION'
                    ,NVL(p_starter_instance_id, l_payload_rec_row.starter_instance_id)
                    ,NVL(I_P_OIC_ID, l_payload_rec_row.oic_instance_id)
                )
            RETURNING EMPLOYEE_REC_ID INTO l_employee_rec_id;

            INSERT INTO I_41_UKG_PERSON_STG 
                (
                    EMPLOYEE_REC_ID
                    ,PAYLOAD_REC_ID
                    ,FILE_NAME
                    ,SOURCE_DOC_ID  
                    ,EMPLOYEE_ID
                    ,FIRST_NAME
                    ,LAST_NAME
                    ,DATE_OF_BIRTH
                    ,EMAIL_ADDRESS
                    ,NATIONAL_ID
                    ,DATE_TIME_CHANGED
                    ,CREATED_BY_NAME
                    ,LAST_UPDATE_BY_NAME
  'INTEGRATIONS'IC_INSTANCE_ID
                ) VALUES (
                    l_employee_rec_id
                    ,l_payload_rec_row.payload_rec_id
                    ,l_payload_rec_row.file_name
                    ,l_source_doc_id
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.EmployeeId' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.FirstName' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.LastName' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.DateOfBirth' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.EmailAddress' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.NationalIdentifier' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,JSON_VALUE(l_payload_rec_row.payload_data, '$.dateTimeChanged' RETURNING VARCHAR2(400) NULL ON ERROR)
                    ,'OIC_INTEGRATION'
                    ,'OIC_INTEGRATION'
                    ,NVL(p_starter_instance_id, l_payload_rec_row.starter_instance_id)
                    ,NVL(I_P_OIC_ID, l_payload_rec_row.oic_instance_id)
                )
            ;


            INSERT INTO I_41_UKG_EMPLOYEES_STG
                (
                    PAYLOAD_REC_ID
                    ,FILE_NAME
                    ,SOURCE_DOC_ID  
                    ,EMPLOYEE_ID
                    ,EMPLOYEE_NUMBER
                    ,HIRE_DATE
                    ,TERMINATION_DATE
                    ,JOB_CODE
                    ,DEPARTMENT_CODE
                    ,LOCATION_CODE
                    ,COMPANY_CODE_LEGAL_EMPLOYER
                    ,WORKER_TYPE
                    ,DATE_TIME_CHANGED
                    ,CREATED_BY_NAME
                    ,LAST_UPDATE_BY_NAME
  'INTEGRATIONS'IC_INSTANCE_ID
                ) SELECT 
                    l_payload_rec_row.payload_rec_id
                    ,l_payload_rec_row.file_name
                    ,l_source_doc_id
                    ,jt.EmployeeId
                    ,jt.EmployeeNumber
                    ,jt.HireDate
                    ,jt.TerminationDate
                    ,jt.JobCode
                    ,jt.DepartmentCode
                    ,jt.LocationCode
                    ,jt.CompanyCodeLegalEmployer
                    ,jt.EmployerType
                    ,jt.dateTimeChanged
                    ,'OIC_INTEGRATION'
                    ,'OIC_INTEGRATION'
                    ,NVL(p_starter_instance_id, l_payload_rec_row.starter_instance_id)
                    ,NVL(I_P_OIC_ID, l_payload_rec_row.oic_instance_id)
                FROM JSON_TABLE(
                    l_payload_rec_row.payload_data,
                    '$[*]'
                    COLUMNS (
                        EmployeeId                  VARCHAR2(400) PATH '$.EmployeeId' NULL ON ERROR
                        ,EmployeeNumber             VARCHAR2(400) PATH '$.EmployeeNumber' NULL ON ERROR
                        ,HireDate                   VARCHAR2(400) PATH '$.HireDate' NULL ON ERROR
                        ,TerminationDate            VARCHAR2(400) PATH '$.TerminationDate' NULL ON ERROR
                        ,JobCode                    VARCHAR2(400) PATH '$.JobCode' NULL ON ERROR
                        ,DepartmentCode             VARCHAR2(400) PATH '$.DepartmentCode' NULL ON ERROR
                        ,LocationCode               VARCHAR2(400) PATH '$.LocationCode' NULL ON ERROR
                        ,CompanyCodeLegalEmployer   VARCHAR2(400) PATH '$.CompanyCodeLegalEmployer' NULL ON ERROR
                        ,EmployerType               VARCHAR2(400) PATH '$.EmployerType' NULL ON ERROR
                        ,dateTimeChanged            VARCHAR2(400) PATH '$.dateTimeChanged' NULL ON ERROR
                    )
                ) jt
            RETURNING EMPLOYEE_REC_ID BULK COLLECT INTO l_employee_rec_ids;  -- ← captures all IDs
            --RETURNING EMPLOYEE_REC_ID INTO l_employee_rec_id;

            INSERT INTO I_41_UKG_PERSON_STG 
                (
                    PAYLOAD_REC_ID
                    ,FILE_NAME
                    ,SOURCE_DOC_ID  
                    ,EMPLOYEE_ID
                    ,FIRST_NAME
                    ,LAST_NAME
                    ,DATE_OF_BIRTH
                    ,EMAIL_ADDRESS
                    ,NATIONAL_ID
                    ,DATE_TIME_CHANGED
                    ,CREATED_BY_NAME
                    ,LAST_UPDATE_BY_NAME
  'INTEGRATIONS'IC_INSTANCE_ID
                ) SELECT 
                    l_payload_rec_row.payload_rec_id
                    ,l_payload_rec_row.file_name
                    ,l_source_doc_id
                    ,jt.EmployeeId
                    ,jt.FirstName
                    ,jt.LastName
                    ,jt.DateOfBirth
                    ,jt.EmailAddress
                    ,jt.NationalIdentifier
                    ,jt.dateTimeChanged
                    ,'OIC_INTEGRATION'
                    ,'OIC_INTEGRATION'
                    ,NVL(p_starter_instance_id, l_payload_rec_row.starter_instance_id)
                    ,NVL(I_P_OIC_ID, l_payload_rec_row.oic_instance_id)
                FROM JSON_TABLE(
                    l_payload_rec_row.payload_data,
                    '$[*]'
                    COLUMNS (
                        EmployeeId                  VARCHAR2(400) PATH '$.EmployeeId' NULL ON ERROR
                        ,FirstName                  VARCHAR2(400) PATH '$.FirstName' NULL ON ERROR
                        ,LastName                   VARCHAR2(400) PATH '$.LastName' NULL ON ERROR
                        ,DateOfBirth                VARCHAR2(400) PATH '$.DateOfBirth' NULL ON ERROR
                        ,EmailAddress               VARCHAR2(400) PATH '$.EmailAddress' NULL ON ERROR
                        ,NationalIdentifier         VARCHAR2(400) PATH '$.NationalIdentifier' NULL ON ERROR
                        ,dateTimeChanged            VARCHAR2(400) PATH '$.dateTimeChanged' NULL ON ERROR
                    )
                ) jt;*/


            UPDATE am_inbound_payloads_raw
            SET processed_flag      = 'Y',
                last_update_date    = SYSDATE,
                last_update_by_name = 'OIC_INTEGRATION',
                error_code          = NULL,
                error_message       = NULL
            WHERE payload_rec_id = l_payload_rec_row.payload_rec_id;

            COMMIT;

            o_p_status := 'SUCCESS';
            o_p_response :=
                'Payload record id=' || l_payload_rec_row.payload_rec_id ||
                ' file_name="' || l_payload_rec_row.file_name || '" processed successfully. ' ||
                CASE
                    WHEN l_employee_counter > 0
                        THEN TO_CHAR(l_employee_counter) || ' employee objects parsed and inserted into Stage Tables.'
                    ELSE 'Employees array is empty. No employee object was parsed nor inserted into Stage Tables.'
                END;

        EXCEPTION
            WHEN e_resource_busy THEN
                o_p_status := 'ERROR';
                o_p_response := 'An error occurred in the PARSE procedure.'
                                || CHR(10) || 'Error Details:'
                                || CHR(10) || TO_CHAR(SQLCODE)
                                || CHR(10) || TO_CHAR(SQLERRM)
                                || CHR(10) || TO_CHAR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE)
                                || CHR(10) || TO_CHAR(DBMS_UTILITY.FORMAT_ERROR_STACK);
                RAISE;

            WHEN NO_DATA_FOUND THEN
                o_p_status := 'ERROR';
                o_p_response := 'Payload not found, already processed, or DOC_TYPE mismatch. p_payload_rec_id='
                                || p_payload_rec_id || ' expected DOC_TYPE=' || I_P_DOC_TYPE;
                RAISE_APPLICATION_ERROR(-20010, o_p_response);

            WHEN OTHERS THEN
                ROLLBACK;

                o_p_status := 'ERROR';
                o_p_response := 'An error occurred in the PARSE procedure.'
                                || CHR(10) || 'ROLLBACK executed.'
                                || CHR(10) || 'Error Details:'
                                || CHR(10) || TO_CHAR(SQLCODE)
                                || CHR(10) || TO_CHAR(SQLERRM)
                                || CHR(10) || TO_CHAR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE)
                                || CHR(10) || TO_CHAR(DBMS_UTILITY.FORMAT_ERROR_STACK);

                l_error_code    := SUBSTR(TO_CHAR(SQLCODE), 1, 64);
                l_error_message := SUBSTR(o_p_response, 1, 4000);

                UPDATE am_inbound_payloads_raw
                SET processed_flag       = 'E',
                    last_update_date     = SYSDATE,
                    last_update_by_name  ='INTEGRATIONS',
                    error_code           = l_error_code,
                    error_message        = l_error_message
                WHERE payload_rec_id = l_payload_rec_row.payload_rec_id;

                COMMIT;
                RAISE;
        END I_41_UKG_EMPLOYEE_PARSE_PRC;

    PROCEDURE I_41_UKG_EMPLOYEE_TRANSFORM_PRC (
            I_P_OIC_ID           IN VARCHAR2
            ,O_P_RESPONSE        OUT CLOB
            ,O_P_STATUS          OUT VARCHAR2
            ,O_P_HAS_MORE_COUNT  OUT NUMBER
        )
        IS
            l_v_MAX_RECORDS_PER_RUN NUMBER := 250;
            l_v_GROUP_ID            NUMBER;
            l_v_ERROR_CODE          VARCHAR2(64);
            l_v_ERROR_MESSAGE       VARCHAR2(4000);

            l_v_po_number           VARCHAR2(200);
        BEGIN            
            O_P_RESPONSE := 'I_41_UKG_EMPLOYEE_TRANSFORM_PRC procedure started.' || CHR(10) || CHR(10);

            -----------------
            -- VALIDATIONS --
            -----------------

            -- Mandatory fields missing
            UPDATE I_41_UKG_EMPLOYEES_STG
            SET last_update_date    = SYSDATE,
                last_update_by_name = 'OIC_INTEGRATION',
                PROCESSED_FLAG      = 'E',
                error_code          = '400',
                error_message       = 'Mandatory fields missing - Hire date or Job code' -- or Department
            WHERE OIC_INSTANCE_ID = I_P_OIC_ID
            AND (HIRE_DATE IS NULL OR JOB_CODE IS NULL); -- OR DEPARTMENT_CODE IS NULL

            -- Mandatory fields missing
            UPDATE I_41_UKG_PERSON_STG
            SET last_update_date    = SYSDATE,
                last_update_by_name = 'OIC_INTEGRATION',
                PROCESSED_FLAG      = 'E',
                error_code          = '400',
                error_message       = 'Mandatory fields missing - Name or Date of birth'
            WHERE OIC_INSTANCE_ID = I_P_OIC_ID
            AND (FIRST_NAME IS NULL OR LAST_NAME IS NULL OR DATE_OF_BIRTH IS NULL);

            -- Minimum age not reached
            UPDATE I_41_UKG_PERSON_STG
            SET last_update_date    = SYSDATE,
                last_update_by_name = 'OIC_INTEGRATION',
                PROCESSED_FLAG      = 'E',
                error_code          = '400',
                error_message       = CASE WHEN error_message IS NULL THEN 'Minimum age not reached' ELSE error_message || ' | Minimum age not reached' END
            WHERE OIC_INSTANCE_ID = I_P_OIC_ID
            AND MONTHS_BETWEEN(SYSDATE, TO_DATE(DATE_OF_BIRTH, 'YYYY-MM-DD')) <= 216;

            -- Hire date earlier than date of birth
            UPDATE I_41_UKG_EMPLOYEES_STG emp
            SET emp.last_update_date    = SYSDATE,
                emp.last_update_by_name = 'OIC_INTEGRATION',
                emp.PROCESSED_FLAG      = 'E',
                emp.error_code          = '400',
                emp.error_message       = CASE WHEN error_message IS NULL THEN 'Hire date earlier than date of birth' ELSE error_message || ' | Hire date earlier than date of birth' END
            WHERE emp.OIC_INSTANCE_ID = 'TEST_SQLDEV'
            AND (TO_DATE(SUBSTR(emp.HIRE_DATE, 1, 10), 'YYYY-MM-DD') - 
                (SELECT TO_DATE(SUBSTR(per.DATE_OF_BIRTH, 1, 10), 'YYYY-MM-DD')
                FROM I_41_UKG_PERSON_STG per
                WHERE per.EMPLOYEE_ID = emp.EMPLOYEE_ID
                AND per.OIC_INSTANCE_ID = 'TEST_SQLDEV'
                )) < 0;

            -- Termination date earlier than hire date
            UPDATE I_41_UKG_EMPLOYEES_STG emp
            SET last_update_date    = SYSDATE,
                last_update_by_name = 'OIC_INTEGRATION',
                PROCESSED_FLAG      = 'E',
                error_code          = '400',
                error_message       = CASE WHEN error_message IS NULL THEN 'Termination date earlier than hire date' ELSE error_message || ' | Termination date earlier than hire date' END
            WHERE emp.OIC_INSTANCE_ID = I_P_OIC_ID
            AND (TO_DATE(SUBSTR(emp.TERMINATION_DATE, 1, 10), 'YYYY-MM-DD') - TO_DATE(SUBSTR(emp.HIRE_DATE, 1, 10), 'YYYY-MM-DD')) < 0;

            --Updating Person and Employee tables to return the same error for the same Employee_ID

            /*-- Updating person table with the same EMPLOYEE_REC_ID where employee table has an error
            UPDATE I_41_UKG_PERSON_STG per
            SET per.last_update_date    = SYSDATE,
                per.last_update_by_name = 'OIC_INTEGRATION',
                per.PROCESSED_FLAG      = 'E',
                per.error_code          = (select error_code from I_41_UKG_EMPLOYEES_STG where EMPLOYEE_REC_ID = per.EMPLOYEE_REC_ID and OIC_INSTANCE_ID = I_P_OIC_ID and PROCESSED_FLAG = 'E'),
                per.error_message       = (select error_message from I_41_UKG_EMPLOYEES_STG where EMPLOYEE_REC_ID = per.EMPLOYEE_REC_ID and OIC_INSTANCE_ID = I_P_OIC_ID and PROCESSED_FLAG = 'E')
            WHERE per.OIC_INSTANCE_ID = I_P_OIC_ID and per.PROCESSED_FLAG = 'N';

            -- Updating person table with the same EMPLOYEE_REC_ID where employee table has an error
            UPDATE I_41_UKG_EMPLOYEES_STG emp
            SET emp.last_update_date    = SYSDATE,
                emp.last_update_by_name = 'OIC_INTEGRATION',
                emp.PROCESSED_FLAG      = 'E',
                emp.error_code          = (select error_code from I_41_UKG_PERSON_STG where EMPLOYEE_ID = emp.EMPLOYEE_ID and OIC_INSTANCE_ID = I_P_OIC_ID and PROCESSED_FLAG = 'E'),
                emp.error_message       = (select error_message from I_41_UKG_PERSON_STG where EMPLOYEE_ID = emp.EMPLOYEE_ID and OIC_INSTANCE_ID = I_P_OIC_ID and PROCESSED_FLAG = 'E')
            WHERE emp.OIC_INSTANCE_ID = I_P_OIC_ID and emp.PROCESSED_FLAG = 'N';*/

            -------------
            -- CURSORS --
            -------------

            SELECT  (MAX(NVL(INTF.EMPLOYEE_INTF_REC_ID,0)) + 1 ) INTO l_v_GROUP_ID
                FROM
                    DUAL
                    LEFT JOIN  I_41_UKG_EMPLOYEES_PERSON_INTF  INTF  ON  1=1
            ;

            FOR EMPLOYEE_REC IN (
                SELECT *
                FROM I_41_UKG_EMPLOYEES_STG
                WHERE PROCESSED_FLAG = 'N'
                ORDER BY
                    EMPLOYEE_REC_ID DESC
                FETCH FIRST l_v_MAX_RECORDS_PER_RUN ROWS ONLY
            ) LOOP
                O_P_RESPONSE := O_P_RESPONSE || '    Processing EMPLOYEE_REC_ID: ' || TO_CHAR(EMPLOYEE_REC.EMPLOYEE_REC_ID, '99999999') || ' from the file name: "' || EMPLOYEE_REC.FILE_NAME || '" | Status: ';


                DECLARE    -- employee BLOCK
                    l_v_EMPLOYEE_INTF_REC_ID    NUMBER;
                    L_V_ALREADY_SUCCEEDED       VARCHAR2(1);
                    L_V_AUX_TEXT                VARCHAR2(256);
                    L_V_NL                      VARCHAR2(32);

                    --Getting employee and person Stg data
                    CURSOR EMPLOYEE_CUR IS
                        SELECT
                            person.PERSON_REC_ID                                                        AS  PERSON_REC_ID
                            ,employee.EMPLOYEE_REC_ID                                                   AS  EMPLOYEE_REC_ID
                            ,employee.PAYLOAD_REC_ID                                                    AS  PAYLOAD_REC_ID
                            ,employee.FILE_NAME                                                         AS  FILE_NAME
                            ,employee.SOURCE_DOC_ID                                                     AS  SOURCE_DOC_ID
                            ,employee.EMPLOYEE_NUMBER                                                   AS  PERSON_NUMBER                                   
                            ,person.FIRST_NAME                                                          AS  FIRST_NAME
                            ,person.LAST_NAME                                                           AS  LAST_NAME
                            ,person.KNOWN_AS                                                            AS  KNOWN_AS
                            ,person.SUFFIX                                                              AS  SUFFIX
                            ,'US'                                                                       AS  LEGISLATION_CODE
                            ,case when employee.COMPANY_CODE_LEGAL_EMPLOYER LIKE 'Contractors%Temp'
                                THEN 'Air Methods LLC'
                                ELSE employee.COMPANY_CODE_LEGAL_EMPLOYER
                            END                                                                         AS  LEGAL_EMPLOYER_NAME
                            ,employee.WORKER_TYPE                                                       AS  WORKER_TYPE
                            ,'E' || employee.EMPLOYEE_NUMBER                                            AS  ASSIGNMENT_NUMBER
                            ,employee.ACTION_CODE                                                       AS  ACTION_CODE
                            ,'ACTIVE_NO_PROCESS'                                                        AS  ASSIGNMENT_STATUS_TYPE_CODE
                            ,CASE employee.BUSINESS_UNIT_NAME
                                WHEN 'UR' THEN 'United Rotorcraft'
                                WHEN 'Tour' THEN 'Blue Hawaiian'
                                ELSE 'Air Methods'
                            END                                                                         AS  BUSINESS_UNIT_NAME
                            ,employee.DEFAULT_EXPENSE_ACCOUNT                                           AS  DEFAULT_EXPENSE_ACCOUNT
                            ,employee.TERMINATION_DATE                                                  AS  TERMINATION_DATE
                            ,job_code.ORACLE_JOB_CODE                                                   AS  JOB_CODE
                            ,null                                                                       AS  LOCATION_CODE
                            --,employee.LOCATION_CODE                                                     AS  LOCATION_CODE
                            ,'LINE_MANAGER'                                                             AS  MANAGER_TYPE
                            ,employee.MANAGER_ASSIGNMENT_NUMBER                                         AS  MANAGER_ASSIGNMENT_NUMBER
                            ,employee.ACTION_CODE                                                       AS  MANAGER_ACTION_CODE
                            ,employee.EMAIL_TYPE                                                        AS  EMAIL_TYPE
                            ,person.EMAIL_ADDRESS                                                       AS  EMAIL_ADDRESS
                            ,'ACTIVE'                                                                   AS  ASSIGNMENT_STATUS
                            ,NULL                                                                       AS  SUPERVISION_QUALIFIER
                            ,employee.HIRE_DATE                                                         AS  REHIRE_DATE
                            --,employee.EMPLOYEE_CHANGE                                                   AS  EMPLOYEE_CHANGE
                            ,DECODE(employee.EMPLOYEE_CHANGE, 'T', 'TERM',
                                    CASE
                                        WHEN worker.PERSON_NUMBER is null THEN 'HIRE'
                                        WHEN (employee.TERMINATION_DATE IS NOT NULL and employee.HIRE_DATE > employee.TERMINATION_DATE)
                                            THEN 'REHIRE'
                                        WHEN employee.EMPLOYEE_CHANGE = 'A' THEN 'UPDATE'
                                        ELSE employee.EMPLOYEE_CHANGE
                                    END)                                                                AS  EMPLOYEE_CHANGE
                            ,employee.ASSIGNMENT_DATE                                                   AS  ASSIGNMENT_DATE
                            ,dept.ORACLE_DEPARTMENT_NAME                                                AS  DEPT_DESC
                            ,employee.START_DATE                                                        AS  START_DATE
                            ,'US'                                                                       AS  LEGISLATION
                            ,'US'                                                                       AS  HOME_ADRESS_COUNTRY
                            ,I_P_OIC_ID                                                                 AS  STARTER_INSTANCE_ID
                            ,I_P_OIC_ID                                                                 AS  OIC_INSTANCE_ID
                        FROM
                            I_41_UKG_EMPLOYEES_STG employee
                            ,I_41_UKG_PERSON_STG person
                            ,I_41_JOB_CODE_UKG_TO_ORACLE_LKP job_code
                            ,PER_PEOPLE_ALL_PVO_INTF worker
                            ,I_41_DEPT_NAME_UKG_TO_ORACLE_LKP dept
                        WHERE employee.EMPLOYEE_ID = person.EMPLOYEE_ID (+)
                        AND employee.PROCESSED_FLAG = 'N'
                        AND person.PROCESSED_FLAG (+) = 'N'
                        AND employee.OIC_INSTANCE_ID = I_P_OIC_ID
                        AND person.OIC_INSTANCE_ID (+) = I_P_OIC_ID
                        AND employee.JOB_CODE = job_code.UKG_JOB_CODE (+)
                        AND employee.EMPLOYEE_NUMBER = worker.PERSON_NUMBER (+)
                        AND employee.DEPARTMENT_CODE = dept.UKG_DEPARTMENT_NAME (+)
                        --and employee.EMPLOYEE_CHANGE = 'REHIRE'
                        --AND employee.EMPLOYEE_NUMBER = '11329'
                    ; --! END OF CURSOR EMPLOYEE_CUR

                BEGIN      -- employee BLOCK




                    FOR EMPLOYEE_REC IN EMPLOYEE_CUR LOOP


                        UPDATE I_41_UKG_EMPLOYEES_STG SET PROCESSED_FLAG = 'P', LAST_UPDATE_DATE = SYSDATE  WHERE EMPLOYEE_REC_ID = EMPLOYEE_REC.EMPLOYEE_REC_ID;

                            COMMIT;

                        l_v_EMPLOYEE_INTF_REC_ID := NULL;


                        INSERT INTO I_41_UKG_EMPLOYEES_PERSON_INTF
                                (
                                    PERSON_REC_ID
                                    ,EMPLOYEE_REC_ID
                                    ,PAYLOAD_REC_ID
                                    ,FILE_NAME
                                    ,SOURCE_DOC_ID
                                    ,PERSON_NUMBER
                                    ,FIRST_NAME
                                    ,LAST_NAME
                                    ,KNOWN_AS
                                    ,SUFFIX
                                    ,LEGISLATION_CODE
                                    ,LEGAL_EMPLOYER_NAME
                                    ,WORKER_TYPE
                                    ,ASSIGNMENT_NUMBER
                                    ,ACTION_CODE
                                    ,ASSIGNMENT_STATUS_TYPE_CODE
                                    ,BUSINESS_UNIT_NAME
                                    ,DEFAULT_EXPENSE_ACCOUNT
                                    ,TERMINATION_DATE
                                    ,JOB_CODE
                                    ,LOCATION_CODE
                                    ,MANAGER_TYPE
                                    ,MANAGER_ASSIGNMENT_NUMBER
                                    ,MANAGER_ACTION_CODE
                                    ,EMAIL_TYPE
                                    ,EMAIL_ADDRESS
                                    ,ASSIGNMENT_STATUS--
                                    ,SUPERVISION_QUALIFIER 
                                    ,REHIRE_DATE
                                    ,EMPLOYEE_CHANGE
                                    ,ASSIGNMENT_DATE
                                    ,DEPT_DESC
                                    ,START_DATE
                                    ,LEGISLATION
                                    ,HOME_ADRESS_COUNTRY--

                                    ,PROCESSED_FLAG
                                    ,STARTER_INSTANCE_ID
                                    ,OIC_INSTANCE_ID
                                ) VALUES (
                                    EMPLOYEE_REC.PERSON_REC_ID
                                    ,EMPLOYEE_REC.EMPLOYEE_REC_ID
                                    ,EMPLOYEE_REC.PAYLOAD_REC_ID
                                    ,EMPLOYEE_REC.FILE_NAME
                                    ,EMPLOYEE_REC.SOURCE_DOC_ID
                                    ,EMPLOYEE_REC.PERSON_NUMBER
                                    ,EMPLOYEE_REC.FIRST_NAME
                                    ,EMPLOYEE_REC.LAST_NAME
                                    ,EMPLOYEE_REC.KNOWN_AS
                                    ,EMPLOYEE_REC.SUFFIX
                                    ,EMPLOYEE_REC.LEGISLATION_CODE
                                    ,EMPLOYEE_REC.LEGAL_EMPLOYER_NAME
                                    ,EMPLOYEE_REC.WORKER_TYPE
                                    ,EMPLOYEE_REC.ASSIGNMENT_NUMBER
                                    ,EMPLOYEE_REC.ACTION_CODE
                                    ,EMPLOYEE_REC.ASSIGNMENT_STATUS_TYPE_CODE
                                    ,EMPLOYEE_REC.BUSINESS_UNIT_NAME
                                    ,EMPLOYEE_REC.DEFAULT_EXPENSE_ACCOUNT
                                    ,EMPLOYEE_REC.TERMINATION_DATE
                                    ,EMPLOYEE_REC.JOB_CODE
                                    ,EMPLOYEE_REC.LOCATION_CODE
                                    ,EMPLOYEE_REC.MANAGER_TYPE
                                    ,EMPLOYEE_REC.MANAGER_ASSIGNMENT_NUMBER
                                    ,EMPLOYEE_REC.MANAGER_ACTION_CODE
                                    ,EMPLOYEE_REC.EMAIL_TYPE
                                    ,EMPLOYEE_REC.EMAIL_ADDRESS
                                    ,EMPLOYEE_REC.ASSIGNMENT_STATUS--
                                    ,EMPLOYEE_REC.SUPERVISION_QUALIFIER 
                                    ,EMPLOYEE_REC.REHIRE_DATE
                                    ,EMPLOYEE_REC.EMPLOYEE_CHANGE
                                    ,EMPLOYEE_REC.ASSIGNMENT_DATE
                                    ,EMPLOYEE_REC.DEPT_DESC
                                    ,EMPLOYEE_REC.START_DATE
                                    ,EMPLOYEE_REC.LEGISLATION
                                    ,EMPLOYEE_REC.HOME_ADRESS_COUNTRY--
                                    ,'Y'
                                    ,EMPLOYEE_REC.STARTER_INSTANCE_ID
                                    ,EMPLOYEE_REC.OIC_INSTANCE_ID
                        ) RETURNING EMPLOYEE_INTF_REC_ID  INTO  l_v_EMPLOYEE_INTF_REC_ID;


                        UPDATE I_41_UKG_EMPLOYEES_STG   SET PROCESSED_FLAG = 'Y', LAST_UPDATE_DATE = SYSDATE  WHERE EMPLOYEE_REC_ID = EMPLOYEE_REC.EMPLOYEE_REC_ID;
                        UPDATE I_41_UKG_PERSON_STG      SET PROCESSED_FLAG = 'Y', LAST_UPDATE_DATE = SYSDATE  WHERE PERSON_REC_ID = EMPLOYEE_REC.PERSON_REC_ID;
                        COMMIT;

                    END LOOP;

                EXCEPTION  -- header BLOCK
                    WHEN OTHERS THEN  
                        L_V_ERROR_CODE := 'I_41_UKG_EMPLOYEE_TRANSFORM_PRC procedure error';
                        L_V_ERROR_MESSAGE := Substr(SQLCODE || ' | ' || SQLERRM || ' | Trace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1 , 4000 );
                        UPDATE I_41_UKG_EMPLOYEES_STG SET PROCESSED_FLAG = 'E', ERROR_CODE = L_V_ERROR_CODE, ERROR_MESSAGE = L_V_ERROR_MESSAGE
                            WHERE EMPLOYEE_REC_ID = EMPLOYEE_REC.EMPLOYEE_REC_ID;
                        IF l_v_EMPLOYEE_INTF_REC_ID IS NOT NULL THEN
                            DELETE FROM I_41_UKG_EMPLOYEES_PERSON_INTF WHERE EMPLOYEE_REC_ID = l_v_EMPLOYEE_INTF_REC_ID;
                        END IF;
                        COMMIT;
                        O_P_RESPONSE := O_P_RESPONSE || 'ERROR' || CHR(10) || CHR(10) || L_V_ERROR_MESSAGE || CHR(10)  || 'EMPLOYEE_REC_ID: ' || to_char(EMPLOYEE_REC.EMPLOYEE_REC_ID) || CHR(10) || 'File name: ' || EMPLOYEE_REC.FILE_NAME || CHR(10) || CHR(10);
                        RAISE;
                END;       -- header BLOCK

                O_P_RESPONSE := O_P_RESPONSE || 'Success.' || CHR(10);
            END LOOP;


            SELECT  COUNT(*)   INTO    O_P_HAS_MORE_COUNT  -- inform to the ouput parameter the count of records that still need to be processed (flag = 'N'). the transform procedure that were not select in this run (the selected ones were updated to flag = 'P' -> ['Y', 'E'])
            FROM I_41_UKG_EMPLOYEES_STG  H_STG
            WHERE H_STG.PROCESSED_FLAG  IN ('N');


            O_P_RESPONSE := O_P_RESPONSE || CHR(10) || CHR(10) || 'I_41_UKG_EMPLOYEE_TRANSFORM_PRC procedure completed successfully.';
            O_P_STATUS := 'SUCCESS';
        EXCEPTION
            WHEN OTHERS THEN
                O_P_STATUS := 'ERROR';
                O_P_RESPONSE := O_P_RESPONSE || CHR(10) || CHR(10) || 'I_41_UKG_EMPLOYEE_TRANSFORM_PRC procedure ended with error.' || CHR(10) || CHR(10) || 'Error: ' || SQLCODE || ' | ' || SQLERRM || ' | Trace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
                RAISE;
    END I_41_UKG_EMPLOYEE_TRANSFORM_PRC;

    PROCEDURE I_41_UKG_EMPLOYEE_GET_INTERFACE_TABLES_DATA_PRC (
            O_P_RESPONSE         OUT CLOB
            ,O_P_JSON            OUT CLOB
            ,O_P_STATUS          OUT VARCHAR2
            ,O_P_HAS_MORE_COUNT  OUT NUMBER
        )
        IS
        BEGIN
            null;

            O_P_RESPONSE := 'GET_INTERFACE_TABLES_DATA procedure started.' || CHR(10) || CHR(10);
            O_P_HAS_MORE_COUNT := 0;
            SELECT 
                JSON_OBJECT( 'Records' VALUE (
                    SELECT
                        JSON_ARRAYAGG(  JSON_OBJECT(
                            emp_intf.*
                        RETURNING CLOB ) RETURNING CLOB )
                    FROM
                        I_41_UKG_EMPLOYEES_PERSON_INTF emp_intf
                    WHERE
                        emp_intf.PROCESSED_FLAG = 'Y'
                        --and emp_intf.PERSON_NUMBER = '11329'
                        --and emp_intf.EMPLOYEE_CHANGE = 'REHIRE'
                        --OR (emp_intf.EMPLOYEE_CHANGE = 'TERM' AND emp_intf.PERSON_NUMBER = '13709'))
                        --and emp_intf.JOB_CODE != 'Employee'
                    )
                    RETURNING CLOB 
                    -- PRETTY 
                    STRICT WITH UNIQUE KEYS 
                ) AS JSON_OUTPUT
                INTO O_P_JSON
            FROM DUAL;

            O_P_RESPONSE := O_P_RESPONSE || '    JSON generated successfully.' || CHR(10) || CHR(10);             

            O_P_RESPONSE := O_P_RESPONSE || 'GET_INTERFACE_TABLES_DATA procedure completed successfully.';
            O_P_STATUS := 'SUCCESS';

        EXCEPTION
            WHEN OTHERS THEN
                O_P_RESPONSE := O_P_RESPONSE    
                    || '    '  || 'ERROR: An error occurred in the GET_INTERFACE_TABLES_DATA procedure.'
                    || '    '  || 'Error Details: ' || SQLCODE           || CHR(10)
                    || '    '  || SQLERRM                                || CHR(10)
                    || '    '  || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE    || CHR(10)
                    || '    '  || DBMS_UTILITY.FORMAT_ERROR_STACK        || CHR(10)
                ;
                O_P_STATUS := 'ERROR';
    END I_41_UKG_EMPLOYEE_GET_INTERFACE_TABLES_DATA_PRC;


END AM_41_UKG_EMPLOYEE_TO_HCM_PKG;