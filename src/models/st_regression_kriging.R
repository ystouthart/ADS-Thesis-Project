###
###  st_regression_kriging.R
###
###  Applies the Spatio-Temporal Regression Kriging model on the regression features.
###
###  Input: Regression features & prediction map (output from st_regression_features.R).
###  Output: Interpolated maps for different moments in time.
###




stRegKrige <- function(res){
  # Load the Regression Features:
  ffile = paste("~/data/processed/regression_features/features", res, ".csv", sep='')
  d <- read.csv(ffile)
  d$date = as.POSIXct(d$date)
  d = d[order(d[,"date"], d[,"X"], d[,"Y"]),]
  coordinates(d) <- ~X+Y
  projection(d) <- projection(utrecht)
  
  # Set factors and scales
  d$road <- as.factor(d$road)
  d$rail <- as.factor(d$rail)
  d$HR <- as.factor(d$HR)
  d$HR = relevel(d$HR, ref=1)
  d$WD <- as.factor(d$WD)
  d$WD = relevel(d$WD, ref="N")
  d$pop <- d$pop/1000
  d$address <- d$address/1000
  
  ####################################################
  # Linear Model:
  
  # Train the model
  lm <- lm(pm2_5_mean ~ address + pop  + road + rail + WD + HR + WS + humidity , data=d, na.action="na.exclude")
  summary(lm)
  
  # Generate predictions
  lm_pred <- predict.lm(lm, se.fit=T)
  
  # Create the prediction dataframe
  pred_df <- data.frame("x"=d@coords[,1], "y"=d@coords[,2], "date"=d$date, "pm2_5"=d$pm2_5_mean, "pred"=lm_pred[["fit"]], "se.fit"=lm_pred[["se.fit"]])
  pred_df$res <- pred_df$pm2_5 - pred_df$pred  
  
  
  # Converting pred_df to 'stars' object (Thanks Lucas :)) 
  sf_data <- st_as_sf(pred_df, coords = c("x", "y"), crs = 28992)
  
  pred_stars = sf_data %>% st_as_sf(coords = c('X','Y'))
  
  xy_ = st_coordinates(unique(pred_stars))
  pred_stars = pred_stars[order(xy_[,"X"], xy_[,"Y"]),]
  
  geom = st_sfc(unique(pred_stars$geometry))
  
  time = as.POSIXct(unique(pred_stars$date))
  time = time[order(time)]
  
  cast = dcast(pred_stars, as.character(geometry) ~ date, value.var = 'res', fun.aggregate = max)  
  mat = as.matrix(cast[,-1])
  
  dims = st_dimensions(space = geom,time = as.POSIXct(time))
  
  pred_stars = st_as_stars(res = mat,dim = dims)
  
  gc()
  
  ####################################################
  # Variogram:
  
  # Creating the Empirical ST Variogram
  vv=variogramST(res~1, pred_stars, cressie=F, boundaries=c(500,1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500), tlags = 0:6)
  
  # Fitting the ST Variogram model
  metric <- vgmST("metric", joint=vgm(psill=25, model="Exp", range=2000, nugget=0), stAni=1200) 
  set.seed(seed=123)
  fitmetric <- fit.StVariogram(vv, metric)
  
  
  ####################################################
  # Kriging of the Residuals:
  
  empty_stars = st_as_stars(value = matrix(1, length(st_dimensions(pred_stars)$space$values), 181), dim = dims)
  
  gc()
  
  
  st_r_kriging = krigeST(res~1,data=pred_stars['res'],
                         newdata=empty_stars['value'], nmax=50, stAni=fitmetric$stAni/3600,
                         modelList = fitmetric, computeVar=T)
  
  gc()
  
  ####################################################
  # PM2.5 LM predictions:
  
  predictors <- d@data[c("address", "pop", "road", "rail", "WD", "HR", "WS", "humidity")]
  full_pred = predict.lm(lm, predictors)
  
  full_pred <- data.frame("date"=d@data[,"date"], "x"=coordinates(d)[,"X"], "y"=coordinates(d)[,"Y"], "lm_pred"=full_pred)
  
  # Convert LM Predictions to "stars" object:
  sf_data <- st_as_sf(full_pred, coords = c("x", "y"), crs = 28992)
  
  full_pred_stars = sf_data %>% st_as_sf(coords = c('X','Y'))
  
  xy_ = st_coordinates(unique(full_pred_stars))
  full_pred_stars = full_pred_stars[order(xy_[,"X"], xy_[,"Y"]),]
  
  geom = st_sfc(unique(full_pred_stars$geometry))
  
  time = as.POSIXct(unique(full_pred_stars$date))
  time = time[order(time)]
  
  cast = dcast(full_pred_stars, as.character(geometry) ~ date, value.var = 'lm_pred', fun.aggregate = max)  
  mat = as.matrix(cast[,-1])
  
  dims = st_dimensions(space = geom,time = as.POSIXct(time))
  
  full_pred_stars = st_as_stars(lm_pred = mat,dim = dims)
  
  gc()
  
  
  ####################################################
  # Add LM Predictions to the Kriged Residuals:
  
  
  total_list = list()
  for (i in 1:length(st_dimensions(st_r_kriging)$time$values)){
    coords <- st_coordinates(st_dimensions(st_r_kriging)$sfc$values)
    total <- data.frame("date"= st_dimensions(st_r_kriging)$time$values[i], "x"=coords[,"X"], "y"=coords[,"Y"], "lm_pred"=full_pred_stars$lm_pred[,i], "krige_pred"=st_r_kriging$var1.pred[,i], "var"=st_r_kriging$var1.var[,i])
    total$sum <- total$lm_pred + total$krige_pred
    total_list[[i]] <- total
  }
  total <- dplyr::bind_rows(total_list)
  total$pm2_5_mean <- d@data$pm2_5_mean # Add the original measurements
  
  gc()
  
  ####################################################
  # Save the results:
  filename = paste("~/output/st_regression_kriging/st_reg_krige_", res, ".csv", sep='')
  write.csv(total, file=filename, row.names=FALSE)

}