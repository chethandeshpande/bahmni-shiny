library("dplyr")

age <- function(from, to) {
  from_lt = as.POSIXlt(from)
  to_lt = as.POSIXlt(to)
  
  age = to_lt$year - from_lt$year
  
  ifelse(to_lt$mon < from_lt$mon |
           (to_lt$mon == from_lt$mon & to_lt$mday < from_lt$mday),
         age - 1, age)
}

fetchData <- function(mysqlPool, psqlPool, shouldFetchAll, startDate, endDate) {
  dbOutput <- list()
  variablesToFetch <- list("BMI","BMI Status", "Systolic",
                           "Diastolic")

  hypertensionConceptId <- mysqlPool %>%
     tbl("concept_name") %>%
     filter(voided == 0, name=="Hypertension",
      concept_name_type=="FULLY_SPECIFIED") %>%
     select(concept_id) %>%
     pull(concept_id)

  codedDiagnosisConceptId <- mysqlPool %>%
     tbl("concept_name") %>%
     filter(voided == 0, name=="Coded Diagnosis",
      concept_name_type=="FULLY_SPECIFIED") %>%
     select(concept_id) %>%
     pull(concept_id)

  if(shouldFetchAll){
    patientWithHypertension <- mysqlPool %>% 
      tbl("obs") %>% 
      filter(voided==0,
       value_coded == hypertensionConceptId,
       concept_id == codedDiagnosisConceptId) %>% 
      select(person_id, encounter_id) %>% 
      collect(n = Inf)
  }else{
    patientWithHypertension <- mysqlPool %>% 
      tbl("obs") %>% 
      filter(voided==0,
       value_coded == hypertensionConceptId,
       concept_id == codedDiagnosisConceptId,
       obs_datetime>=startDate,
       obs_datetime<endDate) %>% 
      select(person_id, encounter_id) %>% 
      collect(n = Inf)
  }

  if(nrow(patientWithHypertension) <= 0){
    return (data.frame())
  }
  encIds <- pull(patientWithHypertension, encounter_id)
  personIds <- pull(patientWithHypertension, person_id)

  hypertensionVisits <- mysqlPool %>%
    tbl("encounter") %>%
    filter(voided==0,
     encounter_id %in% encIds) %>% 
    select(visit_id, patient_id) %>%
    collect(n=Inf)

  visitIds <- pull(hypertensionVisits, visit_id)
  visitDates <- mysqlPool %>%
    tbl("visit") %>%
    filter(voided==0, visit_id %in% visitIds) %>% 
    select(date_started,visit_id) %>%
    collect(n=Inf)

  encountersForHypVisit <- mysqlPool %>%
    tbl("encounter") %>%
    filter(voided==0, visit_id %in% visitIds) %>% 
    select(visit_id,uuid,patient_id) %>%
    collect(n=Inf)

  encounterUUIDs <- pull(encountersForHypVisit, uuid)[]
  query <- "SELECT distinct order_id,external_id from sale_order_line"
  saleOrderLines <- psqlPool %>%
    dbGetQuery(query) %>%
    filter(external_id %in% encounterUUIDs) %>%
    select(order_id, external_id) %>%
    collect(n=Inf)

  saleOrderIds <- pull(saleOrderLines, order_id)
  saleOrders <- psqlPool %>%
    tbl("sale_order") %>%
    filter(id %in% saleOrderIds) %>%
    select(amount_total, id, care_setting) %>%
    collect(n=Inf)

  visitPayments <- encountersForHypVisit %>%
    left_join(saleOrderLines, by=c("uuid"="external_id")) %>%
    distinct(visit_id, order_id, .keep_all=T) %>%
    left_join(saleOrders, by=c("order_id"="id")) %>%
    collect(n=Inf) %>%
    group_by(visit_id, care_setting) %>%
    summarise(Amount = sum(amount_total)) %>%
    select(visit_id, Amount, care_setting)

  hypertensionVisits <- hypertensionVisits %>%
    inner_join(visitDates, by=c("visit_id"="visit_id")) %>%
    inner_join(visitPayments, by=c("visit_id"="visit_id")) %>%
    select(patient_id, date_started, Amount, care_setting) %>%
    rename(`Visit Date` = date_started) %>%
    rename(`Care Setting` = care_setting) %>%
    collect(n=Inf)
  
  patients <- mysqlPool %>%
    tbl("person") %>%
    filter(voided==0, person_id %in% personIds) %>%
    select(person_id, gender, birthdate) %>% 
    collect(n=Inf) %>% 
    mutate(birthdate = ymd(birthdate)) %>% 
    rename(Gender = gender) %>% 
    mutate(Age = age(from=birthdate, to=Sys.Date())) %>% 
    select(-birthdate)

  personAddresses <- mysqlPool %>%
    tbl("person_address") %>%
    filter(voided==0, person_id %in% personIds) %>%
    select(person_id,county_district,state_province) %>%
    collect(n=Inf)

  patientIdentifiers <- mysqlPool %>% 
    tbl("patient_identifier") %>% 
    filter(voided==0,identifier_type==3, patient_id %in% personIds) %>% 
    select(patient_id, identifier) %>% 
    collect(n=Inf)

  patients <- patients %>%
    inner_join(personAddresses, by = c("person_id"="person_id")) %>%
    rename(District = county_district) %>%
    rename(State = state_province) %>%
    inner_join(patientIdentifiers, by = c("person_id"="patient_id")) %>%
    inner_join(hypertensionVisits, by = c("person_id"="patient_id")) %>%
    collect(n=Inf)

  allObsForHypertensionPatients <- mysqlPool %>%
    tbl("obs") %>%
    filter(voided==0, person_id %in% personIds) %>%
    collect(n=Inf)
    
  conceptNames <- mysqlPool %>%
    tbl("concept_name") %>%
    filter(voided == 0, name %in% variablesToFetch,
      concept_name_type=="FULLY_SPECIFIED") %>%
    select(concept_id,name) %>%
    collect(n=Inf) 

  obsForVariables <- allObsForHypertensionPatients %>%
    inner_join(conceptNames, by = c("concept_id"="concept_id")) %>%  
    inner_join(patients, by = c("person_id"="person_id")) %>%
    group_by(person_id, concept_id) %>%
    filter(obs_datetime == max(obs_datetime)) %>%
    ungroup() %>%
    rename(ID=identifier) %>%
    select(ID, name, value_numeric, value_text,
     Age, State, District, Gender, `Visit Date`, Amount, `Care Setting`) %>%
    collect(n = Inf)

    #This is to filter out incorrect data entries.
    #Like Query below should return single row
    #SELECT concept_id,encounter_id,value_numeric,obs_datetime FROM obs WHERE obs_id IN (7211637,7211653);
    #This row says in single encounter same concept has been filled twice at same time
  obsForVariables <- obsForVariables %>% distinct(ID,name, .keep_all = TRUE)
  obsForVariables <- obsForVariables %>% 
    gather(Key, Value, starts_with("value_"), na.rm = T) %>%
    select(-Key) %>%
    spread(name, Value, convert = T)

  obsForVariables
}