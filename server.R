### Libraries #####
library(RColorBrewer)
library(igraph)
library(plotly)
require(shiny)
require(visNetwork, quietly = TRUE)
library(DT)
require(shiny)
library(shinyjs)
library(shinyBS)
library(shinysky)
require("RSQLite")
source("sql_transactions.r")


### Set variables #####
fields <- c("timestamp", "name","email","skills", "skillsDetail","needs","needsDetail","cohort", "affiliation", "location")
# Create color palette: get all available colors (total: 150 --151 including white)
col_palts = brewer.pal.info[brewer.pal.info$category != 'seq',]  # Options: div, seq, qual. Get all but sequential ones. 
color_vector = unique(unlist(mapply(brewer.pal, col_palts$maxcolors, rownames(col_palts))))
color_vector = color_vector[color_vector != '#FFFFFF']  # remove white
initial_colors = sample(color_vector, 20, replace=TRUE)  # sample 20 colors

function(input, output, session) {
    formData <- reactive({
      data = sapply(fields, function(x) input[[x]])  # Aggregate all (edit and add) form data
      data
    })
    
    # observe({input$skills
    #   keyword_exists = input$skills %in% skillsNeedsUnique()
    #   if (any(keyword_exists == FALSE)){
    #      # we can add the last element of the vector as a keyword for the dropdown. Otherwise it'll be automatically added when the data's saved.
    #   }
    # })
    
    observe({
      # check if all mandatory fields have a value
      mandatoryFilled <- vapply(c("name", "skills", "email"),
                                function(x) {
                                  !is.null(input[[x]]) && input[[x]] != ""
                                },
                                logical(1))
      mandatoryFilled <- all(mandatoryFilled)
      # enable/disable the submit button (all mandatory fields need to be filled in, and the e-mail needs to have a correct format)
      shinyjs::toggleState(id = "submit", condition = (mandatoryFilled && isValidEmail(input$email)))
    })
    
    observeEvent(input$submit, { # New data: when the Submit button is clicked, save the form data
      removeModal() # first close the pop-up window
      if(userExists(clean_text(input$name), trimws(input$email))){ # display error message if name&email exist in db
        showModal(modalDialog(
          title = "There was a problem with your entry",
          tags$p("The database already contains an entry for the name you entered:"),
          tags$p(tags$b(sprintf("%s (%s)", input$name, input$email))),
          tags$p("To adapt your entry, select your name in the datatable and click on 'Details / Edit'."),
          footer = modalButton("Ok")))
      } else{
        saveData(formData())
    }})
      
    observeEvent(input$submitDelete,{
      removeUser(value$current)
      removeModal()
    })
    
    observeEvent(input$submitEdit,{
      userInfo <- queryUserInfo(value$current)
      data <- formData()
      data = data[data != ""]
      data$timestamp = 'CURRENT_TIMESTAMP'
      changes = c()
      changes = paste(lapply(names(data),function(x) paste0(x," = '", clean_list_to_string(data[[x]]),"'")), collapse=",")
      editData(changes, value$current)
      removeModal()  # close pop-up(s) when submit button is clicked
    })
    
    ### Table #####
    getBasicInfo <- reactive({
      # have database content as reactive value to be accessed later (i.e. pop-up for details)
      # update with every submit/edit/delete
      input$submit
      input$submitEdit
      input$submitDelete
      queryBasicData()  # query DB to get name, skills & needs
    })
    
    getRowIDs <- reactive({
      data = getBasicInfo() # get results from reactive value that communicates with the db
      data$rowid
    })
    
    skillsNeedsUnique <- reactive({
      data = getBasicInfo() # get results from reactive value that communicates with the db
      sort(unique(data_to_list(paste(data$skills, ", ", data$needs)))) # returns all unique keywords (needs + skills)
    })
    
    getColorPalette <- reactive({
      skills = unique(skillsKeywords())
      if (length(skills) != length(initial_colors)){
        initial_colors <<- sample(color_vector, length(skills), replace=TRUE)  # update palette
      }
      initial_colors
    })
    
    skillsKeywords <- reactive({
      data = getBasicInfo()
      data_to_list(data$skills)
    })
    
    needsKeywords <- reactive({
      data = getBasicInfo()
      data_to_list(data$needs)
    })
    
    tableInfo <- reactive({
      df = getBasicInfo()
      df <- df[ , !(names(df) %in% "rowid")] # No need to show rowid, it's for internal purposes
      names(df) <- c("Name","Skills","Needs")
      #df$Skills <- as.factor(df$Skills) # disabled at the moment because does not recognize comma-separated keywords
      #df$Needs <- as.factor(df$Needs)
      data = data.frame(df, Details = shinyInput(actionButton, length(df$Name), 'details', label = "Details / Edit", onclick = 'Shiny.onInputChange(\"details_button\",  this.id)'))
      })
    
    # Select relevant information to visualize in table
    output$database <- DT::renderDataTable({
      tableInfo()
      },escape=FALSE,
        filter = 'top',
        options = list(pagelength = 10, columnDefs = list(list(targets = c(4), searchable = FALSE)))
    )

    #########################
    ##### Network graph #####
    #########################
    node_pairs <- reactive({
      # set content of graph (nodes & edges). Find pairs of people where skills match needs
      edges <- data.frame()
      nodes <- data.frame()
      data = getBasicInfo()
      skills = strsplit(data$skills, ", ")
      # Go through Needs instead of Skills, they are less
      for (row in 1:nrow(data)){
        #node_connection_size = 1 # Count number of connections for each user. We can use it to determine the size of the node.
        current_need <- string_to_list(data$needs[row])
        for (need in current_need) {
          skilled_idx <- grep(need, skills, ignore.case = TRUE)
          skilled_idx = skilled_idx[skilled_idx!=row] # just to avoid the "self-help" loops (some people enter same keyword for skills/needs, e.g. "R")
          if (length(skilled_idx) > 0){
            #node_connection_size = node_connection_size + length(skilled_idx)  # increase by connections of current skill
            from = data$rowid[skilled_idx]  # due to deletions, rowid != the number of the row in the db, need to adjust.
            to = rep(data$rowid[row], length(from))
            title = need
            edges <- rbind(edges, as.data.frame(t(rbind(to, from, title))))
          }
        }
        #edges = rbind(edges, id = seq.int(nrow(edges)))
        nodes <- rbind(nodes, data.frame(id = data$rowid[row],
                                         name = data$name[row],
                                         skills = data$skills[row],
                                         needs = data$needs[row]))
                                         #,connection_size = node_connection_size))
      }
      #edges <- edges[order(edges$title),]
      list(nodes = nodes, edges = edges) # returns nodes and edges (pairs)
    })
    
    networkgraph <- reactive({ 
      graphinfo <- node_pairs()
      nodes <- graphinfo$nodes
      edges <- graphinfo$edges
      #### set visual parameters of graph  ####
      nodes$shadow = TRUE
      nodes$title <- nodes$name
      nodes$size <- 12 # CT: I actually like uniformity in the nodes, but if you want to play with the size of the connections: #nodes$connection_size * 3 (or any other number)
      nodes$color.background <- "#4bd8c1"
      nodes$color.border <- "#42b2a0"
      nodes$color.highlight.background <- "#4bd8c1"
      nodes$color.highlight.border <- "#006600"
      #set edge parameters
      if (nrow(edges) > 0) {  # make sure there are connections to show
        edges$smooth <- FALSE    # should the edges be curved? -- Chara: I actually like the curved edges and the bouncing effect on loading so I vote for TRUE
        edges$width <- 5 # edge shadow
      } else {  # "edge case" :P -- no edges to show
        # select random entry id (here:20) and link it to itself
        edges <- data.frame(from = c(20), to = c(20))
      }
      visNetwork(nodes, edges) %>%
        visIgraphLayout(layout = "layout_in_circle") %>%
        visOptions(highlightNearest = FALSE) %>%  #nodesIdSelection = TRUE #selectedBy = list(variable = "Skills")
        visInteraction(hover = TRUE, hoverConnectedEdges = TRUE, dragNodes = FALSE, zoomView = FALSE, tooltipDelay = 150, dragView = FALSE) %>%
        visEvents(click = "function(nodes){ Shiny.onInputChange('current_node_id', nodes.nodes); }")
    })
    
    output$network <- renderVisNetwork({
      networkgraph()
    })
    
    # If search function in datatable is used, clear selection)
    observeEvent(input$database_rows_all, {
      proxy = dataTableProxy('database')
      selectRows(proxy, NULL)
    })
    
    observeEvent(c(input$database_rows_all,input$database_rows_selected), {
      graphinfo <- node_pairs()  # access reactive values
      nodes <- graphinfo$nodes
      edges <- graphinfo$edges
      skills = unique(skillsKeywords())
      colors = data.frame(skills = skills, colors = c(color = getColorPalette()), stringsAsFactors=FALSE)
      nodes$color.background <- "#4bd8c1"
      nodes$color.border <- "white" # node border color of unselected nodes
      if (nrow(edges) > 0) {  # make sure there are connections to show
        edges$color <- colors$colors[match(edges$title, colors$skills)]  #color all edges (lines)
        edges$width <- 5  # edge shadow
        edges$arrows <- "to"
        indx = input$database_rows_all  # (filtered) rows on all pages
        if (!is.null(input$database_rows_selected)){
          indx = input$database_rows_selected
          # Gray out non selected edges (those that belong to nodes that have not been selected)
          rowIDs = getRowIDs()
          non_selected = intersect(which(edges$from%in%setdiff(edges$from,rowIDs[indx])),which(edges$to%in%setdiff(edges$to,rowIDs[indx])))
          #edges = edges[!rownames(edges) %in% non_selected,]  # part of the attempt to remove edges instead of "graying them out"
          #removed_edges = edges[rownames(edges) %in% non_selected,]
          #visNetworkProxy("network") %>%
          #    visRemoveEdges(id=rownames(removed_edges))  # visRemoveEdges(removed_edges) didn't seem to work either
          edges$color[non_selected] <- "fff"
        }
        nodes$color.border[indx] <- "#42b2a0"  # border color of selected nodes
      }
      # Update network
      visNetworkProxy("network") %>%
        visUpdateNodes(nodes) %>%
        visUpdateEdges(edges)
    })

    ### pie plots #####
    output$piePlotSkills <- renderPlotly({
      skills = skillsKeywords()
      frequencies <-as.data.frame(table(skills))
      plot_ly(frequencies, labels = ~skills, values = ~Freq, type = 'pie',
              textposition = 'inside',
              textinfo = 'percent',
              hoverinfo = 'text',
              text = ~skills,
              marker = list(colors = c(color = brewer.pal(length(skills),"Paired")), # colors do not correspond to colors in network graph
                            line = list(color = '#FFFFFF', width = 2)),
              showlegend = TRUE
      ) %>%
      layout(title = 'Skills',
             xaxis = list(showgrid = FALSE, zeroline = FALSE, showticklabels = FALSE),
             yaxis = list(showgrid = FALSE, zeroline = FALSE, showticklabels = FALSE))
    })
    
    output$piePlotNeeds <- renderPlotly({
      needs = needsKeywords()
      frequencies <-as.data.frame(table(needs))
      plot_ly(frequencies, labels = ~needs, values = ~Freq, type = 'pie',
              textposition = 'inside',
              textinfo = 'percent',
              hoverinfo = 'text',
              text = ~needs,
              marker = list(colors = c(color = brewer.pal(length(needs),"Paired")),
                            line = list(color = '#FFFFFF', width = 2)),
              showlegend = TRUE
      ) %>%
      layout(title = 'Needs',
             xaxis = list(showgrid = FALSE, zeroline = FALSE, showticklabels = FALSE),
             yaxis = list(showgrid = FALSE, zeroline = FALSE, showticklabels = FALSE))
    })
    
    ### Detailed view of user#####
    value <- reactiveValues()
    
    observeEvent(c(input$details_button,input$current_node_id), {
      if (!is.null(input$current_node_id)) {  # when user clicks on network nodes
        current = input$current_node_id
      } else {  # when user clicks on table "Details" button
        rowID = getRowIDs()
        current = rowID[as.numeric(input$details_button)]  # need to update id according to data rowid. as.numeric is compulsory otherwise is returns NA
      }
      userInfo <- queryUserInfo(current)
      showModal(modalDialog(
        title= sprintf("%s (%s)", userInfo$name, userInfo$email),
        renderUI({
          tagList(tags$p(tags$b("Skills: "), userInfo$skills),
                  if (userInfo$skillsDetail != ""){
                    tags$ul(tags$li(userInfo$skillsDetail))
                  },
                  if (userInfo$needs != ""){
                    tags$p(tags$b("Needs: "), userInfo$needs)
                  },
                  if (userInfo$needsDetail != ""){
                    tags$ul(tags$li(userInfo$needsDetail))
                  },
                  tags$p(tags$b("Cohort: "), userInfo$cohort),
                  tags$p(tags$b("Location: "), userInfo$location),
                  tags$p(tags$b("(Primary) affiliation: "), userInfo$affiliation))
        }),
        footer = modalButton("close"),actionButton("buttonEdit","Make edits"), actionButton("buttonDelete", "Delete data")
      ))
      value$current <- current
      session$sendCustomMessage(type = "resetValue", message = "current_node_id")
      session$sendCustomMessage(type = "resetValue", message = "details_button")
    })
    
    observeEvent(input$buttonEdit, {
      userInfo <- queryUserInfo(value$current)
      title = sprintf("Edit Data for: %s", userInfo$name)
      actionButtonName = "submitEdit"
      dataForm(title, actionButtonName, userInfo)
    })

    observeEvent(input$buttonAdd, {
      title = "Add your data"
      actionButtonName = "submit"
      userInfo = data.frame(name = "", email = "", skills = "", skillsDetail = "", needs="", needsDetail="", cohort=2017, affiliation="IMPRS", location="Nijmegen")
      dataForm(title, actionButtonName, userInfo)
    })
    
    dataForm <- function(title, actionButtonName, userInfo){
        if (userInfo$skills == "") {
          selected_skills = NULL
          selected_needs = NULL
        } else {
          selected_skills = string_to_list(userInfo$skills)
          selected_needs = string_to_list(userInfo$needs)
        }
        showModal(modalDialog(
          title = title,
          textInput("name", labelMandatory("Name"), value = userInfo$name), 
          textInput("email", labelMandatory("Email"), value = userInfo$email),
          select2Input("skills", tags$b(labelMandatory("Skills: select from list or add a non available keyword and hit enter")), 
                       choices = skillsNeedsUnique(), selected = selected_skills, multiple = TRUE),
          textInput("skillsDetail", "(Optional) comments on skills", value = userInfo$skillsDetail),
          select2Input("needs", tags$b("Needs: select from list or add a non available keyword and hit enter"), 
                       choices = skillsNeedsUnique(), selected = selected_needs, multiple = TRUE),
          textInput("needsDetail", "(Optional) comments on needs",value = userInfo$needsDetail),
          selectInput("cohort", "Cohort", choices=c(2014:2017), selected=userInfo$cohort),
          selectInput("affiliation", "(Primary) affiliation", choices=c("LiI", "IMPRS"), selected=userInfo$affiliation),
          selectInput("location", "Location", choices=c("Amsterdam", "Leiden", "Maastricht", "Nijmegen", "Tilburg", "Utrecht"), selected=userInfo$location),
          footer = tagList(modalButton("Cancel"), actionButton(actionButtonName, "Submit")))
        )
    }
    
    observeEvent(input$buttonDelete,{
      userInfo <- queryUserInfo(value$current)
      showModal(modalDialog(
        title = sprintf("Are you sure you want to delete all data for: %s (%s)?", userInfo$name, userInfo$email),
        footer = tagList(modalButton("No, cancel"), actionButton("submitDelete", "Confirm & Delete")))
      )
    })
}
