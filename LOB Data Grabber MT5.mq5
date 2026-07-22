//+------------------------------------------------------------------+
//|                                       LOB Data Grabber MT5.mq5   |
//|                      Coleta ampliada de métricas do livro        |
//+------------------------------------------------------------------+
#property copyright "André Luís Lopes da Silva"
#property version   "3.10"
#property description "Coleta métricas clássicas e avançadas do livro de ofertas em 1s - book ordenado"

//--- Parâmetros
input string   InpSymbolInput      = "";               // Símbolo. Vazio = símbolo do gráfico
input int      InpLevels           = 5;                // Níveis de profundidade. Recomendo 5
input int      InpTimerMs          = 1000;             // Intervalo de amostragem em ms
input int      InpEmaPeriod        = 5;                // Período da EMA
input int      InpFlushIntervalSec = 10;               // Flush do CSV a cada X segundos
input string   InpFileName         = "Metrics";        // Nome base do arquivo
input bool     InpSaveRawLevels    = true;             // Salvar preços/volumes brutos dos níveis

//--- Símbolo operacional
string InpSymbol;

//--- Buffers EMA das métricas originais
double emaRatio, emaImbalance, emaTotalDepth, emaSlopeBid, emaSlopeAsk;
double emaSpread, emaTopRatio, emaImbalN1, emaImbalDeep;
double emaDepthDelta, emaMicroPriceDist, emaAggBuy, emaAggSell;

//--- Buffers EMA das métricas novas
double emaWeightedImbalance, emaPressureBid, emaPressureAsk, emaPressureRatio;
double emaWeightedMicroDist, emaDepthConc2, emaDepthConc3, emaDepthConc5;
double emaBookEntropy, emaBookSymmetry, emaBookConvexity;

//--- Valores anteriores para deltas
double prevBidVol1, prevAskVol1, prevTotalDepth;
double prevRatio, prevImbalance, prevSpread, prevMicroDist;
double prevSlopeBid, prevSlopeAsk;
double prevWeightedImbalance, prevPressureRatio, prevWeightedMicroDist;
double prevDepthConc2, prevBookEntropy;

bool   emaInitialized;
bool   prevValid;
int    lastFlushTime;

string csvLines[];
int    lineCount;
int    fileHandle;
string fileNameFull;

//+------------------------------------------------------------------+
//| Funções auxiliares                                               |
//+------------------------------------------------------------------+
double SafeDiv(double num, double den, double fallback=0.0)
  {
   if(MathAbs(den) <= 1e-12) return fallback;
   return num / den;
  }

// Entropia normalizada [0,1] dos volumes do livro
// 0 = concentrado; 1 = bem distribuído
double NormalizedEntropy(const double &vols[], int n)
  {
   double sum = 0.0;
   for(int i=0; i<n; i++) sum += MathMax(0.0, vols[i]);
   if(sum <= 0.0 || n <= 1) return 0.0;

   double h = 0.0;
   for(int i=0; i<n; i++)
     {
      double p = MathMax(0.0, vols[i]) / sum;
      if(p > 0.0) h -= p * MathLog(p);
     }
   return h / MathLog((double)n);
  }



// Insere/agrega um nível BID mantendo ordenação por preço decrescente
// BidPrice1 será sempre o maior preço comprador disponível.
void AddBidLevel(const double price, const double vol, double &prices[], double &vols[], int &count, const int maxLevels)
  {
   if(price <= 0.0 || vol <= 0.0) return;

   // Agrega se o preço já existe nos níveis retidos
   for(int i=0; i<count; i++)
     {
      if(MathAbs(prices[i] - price) <= 1e-9)
        {
         vols[i] += vol;
         return;
        }
     }

   int pos = 0;
   while(pos < count && prices[pos] > price) pos++;

   if(pos >= maxLevels) return;

   int last = MathMin(count, maxLevels-1);
   for(int j=last; j>pos; j--)
     {
      prices[j] = prices[j-1];
      vols[j]   = vols[j-1];
     }

   prices[pos] = price;
   vols[pos]   = vol;
   if(count < maxLevels) count++;
  }

// Insere/agrega um nível ASK mantendo ordenação por preço crescente
// AskPrice1 será sempre o menor preço vendedor disponível.
void AddAskLevel(const double price, const double vol, double &prices[], double &vols[], int &count, const int maxLevels)
  {
   if(price <= 0.0 || vol <= 0.0) return;

   // Agrega se o preço já existe nos níveis retidos
   for(int i=0; i<count; i++)
     {
      if(MathAbs(prices[i] - price) <= 1e-9)
        {
         vols[i] += vol;
         return;
        }
     }

   int pos = 0;
   while(pos < count && prices[pos] < price) pos++;

   if(pos >= maxLevels) return;

   int last = MathMin(count, maxLevels-1);
   for(int j=last; j>pos; j--)
     {
      prices[j] = prices[j-1];
      vols[j]   = vols[j-1];
     }

   prices[pos] = price;
   vols[pos]   = vol;
   if(count < maxLevels) count++;
  }

//+------------------------------------------------------------------+
//| Inicialização                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   InpSymbol = (InpSymbolInput == "") ? _Symbol : InpSymbolInput;

   if(InpLevels < 1 || InpLevels > 5)
     {
      Print("InpLevels deve estar entre 1 e 5. Valor atual=", InpLevels);
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(!MarketBookAdd(InpSymbol))
     {
      Print("Erro ao subscrever MarketBook para ", InpSymbol, " erro=", GetLastError());
      return(INIT_FAILED);
     }

   emaInitialized = false;
   prevValid = false;
   lastFlushTime = (int)TimeCurrent();
   ArrayResize(csvLines, 0);
   lineCount = 0;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   fileNameFull = InpFileName + "_" + IntegerToString(now.year) +
                  StringFormat("%02d%02d_%02d%02d%02d", now.mon, now.day, now.hour, now.min, now.sec) + ".csv";
   fileHandle = INVALID_HANDLE;

   EventSetMillisecondTimer(InpTimerMs);
   Print("DepthMeter v3 iniciado | Symbol=", InpSymbol, " | Timer=", InpTimerMs, "ms | Levels=", InpLevels);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Finalização                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   MarketBookRelease(InpSymbol);
   FlushToCSV();
   if(fileHandle != INVALID_HANDLE) FileClose(fileHandle);
   Print("DepthMeter v3 finalizado.");
  }

//+------------------------------------------------------------------+
//| Timer                                                            |
//+------------------------------------------------------------------+
void OnTimer()
  {
   // Trava: uma linha por segundo, mesmo que o timer dispare mais vezes
   static datetime lastSavedSecond = 0;
   datetime nowSec = TimeCurrent();
   if(nowSec == lastSavedSecond)
      return;
   lastSavedSecond = nowSec;

   MqlBookInfo book[];
   if(!MarketBookGet(InpSymbol, book))
      return;

   double bidVol[5]    = {0,0,0,0,0};
   double askVol[5]    = {0,0,0,0,0};
   double bidPrices[5] = {0,0,0,0,0};
   double askPrices[5] = {0,0,0,0,0};
   int bidCount = 0, askCount = 0;

   // IMPORTANTE:
   // MarketBookGet() não deve ser assumido como ordenado.
   // Para evitar viés metodológico em BidVol1/AskVol1, percorremos TODO o book
   // e mantemos explicitamente os melhores níveis:
   // - BID em ordem decrescente de preço
   // - ASK em ordem crescente de preço
   for(int i=0; i<ArraySize(book); i++)
     {
      double v = (double)book[i].volume;
      if(v <= 0.0 && book[i].volume_real > 0.0)
         v = book[i].volume_real;

      if(book[i].type == BOOK_TYPE_BUY)
         AddBidLevel(book[i].price, v, bidPrices, bidVol, bidCount, InpLevels);
      else if(book[i].type == BOOK_TYPE_SELL)
         AddAskLevel(book[i].price, v, askPrices, askVol, askCount, InpLevels);
     }

   if(bidCount < 1 || askCount < 1)
      return;

   // Auditoria mínima: book não deve estar cruzado/invertido após ordenação.
   if(bidPrices[0] <= 0.0 || askPrices[0] <= 0.0 || bidPrices[0] >= askPrices[0])
     {
      Print("BOOK_INVALID_OR_CROSSED | Bid1=", DoubleToString(bidPrices[0],2),
            " Ask1=", DoubleToString(askPrices[0],2),
            " bidCount=", bidCount,
            " askCount=", askCount);
      return;
     }

   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   if(point <= 0.0) point = _Point;

   //--- Métricas básicas
   double bidVolSum = 0.0, askVolSum = 0.0;
   for(int i=0; i<bidCount; i++) bidVolSum += bidVol[i];
   for(int i=0; i<askCount; i++) askVolSum += askVol[i];

   double totalDepth = bidVolSum + askVolSum;
   double ratio      = SafeDiv(bidVolSum, askVolSum, 0.0);
   double imbalance  = SafeDiv(bidVolSum - askVolSum, totalDepth, 0.0);

   //--- Slopes lineares
   double slopeBid = 0.0, slopeAsk = 0.0;
   if(bidCount >= 2)
     {
      double sx=0, sy=0, sxy=0, sx2=0;
      for(int i=0; i<bidCount; i++)
        {
         double x = i;
         double y = bidVol[i];
         sx += x; sy += y; sxy += x*y; sx2 += x*x;
        }
      double denom = bidCount*sx2 - sx*sx;
      if(denom != 0.0) slopeBid = (bidCount*sxy - sx*sy) / denom;
     }

   if(askCount >= 2)
     {
      double sx=0, sy=0, sxy=0, sx2=0;
      for(int i=0; i<askCount; i++)
        {
         double x = i;
         double y = askVol[i];
         sx += x; sy += y; sxy += x*y; sx2 += x*x;
        }
      double denom = askCount*sx2 - sx*sx;
      if(denom != 0.0) slopeAsk = (askCount*sxy - sx*sy) / denom;
     }

   //--- Métricas já existentes
   double spread = (askPrices[0] - bidPrices[0]) / point;
   double topRatio = SafeDiv(bidVol[0] + askVol[0], totalDepth, 0.0);
   double imbalN1 = SafeDiv(bidVol[0] - askVol[0], bidVol[0] + askVol[0], 0.0);

   double volDeepBid=0.0, volDeepAsk=0.0;
   for(int i=1; i<bidCount; i++) volDeepBid += bidVol[i];
   for(int i=1; i<askCount; i++) volDeepAsk += askVol[i];
   double imbalDeep = SafeDiv(volDeepBid - volDeepAsk, volDeepBid + volDeepAsk, 0.0);

   double depthDelta = 0.0;
   if(prevValid) depthDelta = totalDepth - prevTotalDepth;

   double microPrice = SafeDiv(bidPrices[0]*askVol[0] + askPrices[0]*bidVol[0], bidVol[0]+askVol[0], 0.0);
   double lastPrice  = SymbolInfoDouble(InpSymbol, SYMBOL_LAST);
   double microDist  = (microPrice > 0.0) ? (lastPrice - microPrice) / point : 0.0;

   double aggBuy = 0.0, aggSell = 0.0;
   if(prevValid)
     {
      // Proxy de agressão por consumo da fila do topo:
      // - redução no ASK sugere agressão compradora;
      // - redução no BID sugere agressão vendedora.
      // Observação: isto ainda mistura execução e cancelamento; não substitui Times & Trades.
      aggBuy  = MathMax(0.0, prevAskVol1 - askVol[0]);
      aggSell = MathMax(0.0, prevBidVol1 - bidVol[0]);
     }

   //+--------------------------------------------------------------+
   //| Novas métricas clássicas de livro                            |
   //+--------------------------------------------------------------+

   // 1) Weighted imbalance: níveis mais próximos recebem maior peso
   double weightedBid = 0.0, weightedAsk = 0.0;
   for(int i=0; i<InpLevels; i++)
     {
      double w = (double)(InpLevels - i); // Ex.: 5,4,3,2,1
      weightedBid += w * bidVol[i];
      weightedAsk += w * askVol[i];
     }
   double weightedImbalance = SafeDiv(weightedBid - weightedAsk, weightedBid + weightedAsk, 0.0);

   // 2) Book pressure: volume ponderado pela proximidade do topo
   double pressureBid = 0.0, pressureAsk = 0.0;
   for(int i=0; i<InpLevels; i++)
     {
      double dist = (double)(i + 1);
      pressureBid += SafeDiv(bidVol[i], dist, 0.0);
      pressureAsk += SafeDiv(askVol[i], dist, 0.0);
     }
   double pressureRatio = SafeDiv(pressureBid, pressureAsk, 0.0);

   // 3) Weighted microprice usando pressão dos cinco níveis
   // Se a pressão compradora é maior, o micropreço desloca para o ask.
   double weightedMicroPrice = SafeDiv(bidPrices[0]*pressureAsk + askPrices[0]*pressureBid,
                                       pressureBid + pressureAsk,
                                       microPrice);
   double weightedMicroDist = (weightedMicroPrice > 0.0) ? (lastPrice - weightedMicroPrice) / point : 0.0;

   // 4) Concentração da profundidade nos níveis próximos
   double top2Depth = 0.0, top3Depth = 0.0, top5Depth = 0.0;
   for(int i=0; i<InpLevels; i++)
     {
      double v = bidVol[i] + askVol[i];
      if(i < 2) top2Depth += v;
      if(i < 3) top3Depth += v;
      if(i < 5) top5Depth += v;
     }
   double depthConc2 = SafeDiv(top2Depth, totalDepth, 0.0);
   double depthConc3 = SafeDiv(top3Depth, totalDepth, 0.0);
   double depthConc5 = SafeDiv(top5Depth, totalDepth, 0.0); // com InpLevels=5 tende a 1

   // 5) Entropia do livro: distribuição dos volumes nos dois lados
   double allVols[10];
   for(int i=0; i<5; i++)
     {
      allVols[i]   = bidVol[i];
      allVols[i+5] = askVol[i];
     }
   double bookEntropy = NormalizedEntropy(allVols, 10);

   // 6) Simetria entre lados: 1 = simétrico; 0 = muito assimétrico
   double bookSymmetry = 1.0 - MathAbs(imbalance);

   // 7) Convexidade simples do livro
   // Compara concentração no topo contra profundidade mais distante
   double nearDepth = 0.0, farDepth = 0.0;
   for(int i=0; i<InpLevels; i++)
     {
      double v = bidVol[i] + askVol[i];
      if(i < 2) nearDepth += v;
      if(i >= 2) farDepth += v;
     }
   double bookConvexity = SafeDiv(nearDepth, farDepth, 0.0);

   //--- Deltas dinâmicos de 1 segundo
   double dRatio = 0.0, dImbalance = 0.0, dTotalDepth = 0.0, dSpread = 0.0, dMicroDist = 0.0;
   double dSlopeBid = 0.0, dSlopeAsk = 0.0;
   double dWeightedImbalance = 0.0, dPressureRatio = 0.0, dWeightedMicroDist = 0.0;
   double dDepthConc2 = 0.0, dBookEntropy = 0.0;

   if(prevValid)
     {
      dRatio              = ratio - prevRatio;
      dImbalance          = imbalance - prevImbalance;
      dTotalDepth         = totalDepth - prevTotalDepth;
      dSpread             = spread - prevSpread;
      dMicroDist          = microDist - prevMicroDist;
      dSlopeBid           = slopeBid - prevSlopeBid;
      dSlopeAsk           = slopeAsk - prevSlopeAsk;
      dWeightedImbalance  = weightedImbalance - prevWeightedImbalance;
      dPressureRatio      = pressureRatio - prevPressureRatio;
      dWeightedMicroDist  = weightedMicroDist - prevWeightedMicroDist;
      dDepthConc2         = depthConc2 - prevDepthConc2;
      dBookEntropy        = bookEntropy - prevBookEntropy;
     }

   //--- EMAs
   if(!emaInitialized)
     {
      emaRatio=ratio; emaImbalance=imbalance; emaTotalDepth=totalDepth;
      emaSlopeBid=slopeBid; emaSlopeAsk=slopeAsk;
      emaSpread=spread; emaTopRatio=topRatio; emaImbalN1=imbalN1;
      emaImbalDeep=imbalDeep; emaDepthDelta=depthDelta;
      emaMicroPriceDist=microDist; emaAggBuy=aggBuy; emaAggSell=aggSell;

      emaWeightedImbalance=weightedImbalance;
      emaPressureBid=pressureBid; emaPressureAsk=pressureAsk; emaPressureRatio=pressureRatio;
      emaWeightedMicroDist=weightedMicroDist;
      emaDepthConc2=depthConc2; emaDepthConc3=depthConc3; emaDepthConc5=depthConc5;
      emaBookEntropy=bookEntropy; emaBookSymmetry=bookSymmetry; emaBookConvexity=bookConvexity;

      emaInitialized=true;
     }
   else
     {
      double a = 2.0 / (InpEmaPeriod + 1.0);

      emaRatio += a*(ratio - emaRatio);
      emaImbalance += a*(imbalance - emaImbalance);
      emaTotalDepth += a*(totalDepth - emaTotalDepth);
      emaSlopeBid += a*(slopeBid - emaSlopeBid);
      emaSlopeAsk += a*(slopeAsk - emaSlopeAsk);
      emaSpread += a*(spread - emaSpread);
      emaTopRatio += a*(topRatio - emaTopRatio);
      emaImbalN1 += a*(imbalN1 - emaImbalN1);
      emaImbalDeep += a*(imbalDeep - emaImbalDeep);
      emaDepthDelta += a*(depthDelta - emaDepthDelta);
      emaMicroPriceDist += a*(microDist - emaMicroPriceDist);
      emaAggBuy += a*(aggBuy - emaAggBuy);
      emaAggSell += a*(aggSell - emaAggSell);

      emaWeightedImbalance += a*(weightedImbalance - emaWeightedImbalance);
      emaPressureBid += a*(pressureBid - emaPressureBid);
      emaPressureAsk += a*(pressureAsk - emaPressureAsk);
      emaPressureRatio += a*(pressureRatio - emaPressureRatio);
      emaWeightedMicroDist += a*(weightedMicroDist - emaWeightedMicroDist);
      emaDepthConc2 += a*(depthConc2 - emaDepthConc2);
      emaDepthConc3 += a*(depthConc3 - emaDepthConc3);
      emaDepthConc5 += a*(depthConc5 - emaDepthConc5);
      emaBookEntropy += a*(bookEntropy - emaBookEntropy);
      emaBookSymmetry += a*(bookSymmetry - emaBookSymmetry);
      emaBookConvexity += a*(bookConvexity - emaBookConvexity);
     }

   //--- Monta linha CSV
   string line = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + ";" +
                 DoubleToString(lastPrice, 2) + ";" +
                 DoubleToString(bidPrices[0], 2) + ";" +
                 DoubleToString(askPrices[0], 2) + ";" +

                 DoubleToString(ratio,5) + ";" +
                 DoubleToString(imbalance,5) + ";" +
                 DoubleToString(totalDepth,0) + ";" +
                 DoubleToString(slopeBid,2) + ";" +
                 DoubleToString(slopeAsk,2) + ";" +
                 DoubleToString(spread,2) + ";" +
                 DoubleToString(topRatio,4) + ";" +
                 DoubleToString(imbalN1,4) + ";" +
                 DoubleToString(imbalDeep,4) + ";" +
                 DoubleToString(depthDelta,0) + ";" +
                 DoubleToString(microDist,2) + ";" +
                 DoubleToString(aggBuy,0) + ";" +
                 DoubleToString(aggSell,0) + ";" +

                 DoubleToString(weightedImbalance,5) + ";" +
                 DoubleToString(pressureBid,2) + ";" +
                 DoubleToString(pressureAsk,2) + ";" +
                 DoubleToString(pressureRatio,5) + ";" +
                 DoubleToString(weightedMicroPrice,2) + ";" +
                 DoubleToString(weightedMicroDist,2) + ";" +
                 DoubleToString(depthConc2,4) + ";" +
                 DoubleToString(depthConc3,4) + ";" +
                 DoubleToString(depthConc5,4) + ";" +
                 DoubleToString(bookEntropy,5) + ";" +
                 DoubleToString(bookSymmetry,5) + ";" +
                 DoubleToString(bookConvexity,5) + ";" +

                 DoubleToString(dRatio,5) + ";" +
                 DoubleToString(dImbalance,5) + ";" +
                 DoubleToString(dTotalDepth,0) + ";" +
                 DoubleToString(dSpread,2) + ";" +
                 DoubleToString(dMicroDist,2) + ";" +
                 DoubleToString(dSlopeBid,2) + ";" +
                 DoubleToString(dSlopeAsk,2) + ";" +
                 DoubleToString(dWeightedImbalance,5) + ";" +
                 DoubleToString(dPressureRatio,5) + ";" +
                 DoubleToString(dWeightedMicroDist,2) + ";" +
                 DoubleToString(dDepthConc2,5) + ";" +
                 DoubleToString(dBookEntropy,5) + ";" +

                 DoubleToString(emaRatio,5) + ";" +
                 DoubleToString(emaImbalance,5) + ";" +
                 DoubleToString(emaTotalDepth,0) + ";" +
                 DoubleToString(emaSlopeBid,2) + ";" +
                 DoubleToString(emaSlopeAsk,2) + ";" +
                 DoubleToString(emaSpread,2) + ";" +
                 DoubleToString(emaTopRatio,4) + ";" +
                 DoubleToString(emaImbalN1,4) + ";" +
                 DoubleToString(emaImbalDeep,4) + ";" +
                 DoubleToString(emaDepthDelta,0) + ";" +
                 DoubleToString(emaMicroPriceDist,2) + ";" +
                 DoubleToString(emaAggBuy,0) + ";" +
                 DoubleToString(emaAggSell,0) + ";" +

                 DoubleToString(emaWeightedImbalance,5) + ";" +
                 DoubleToString(emaPressureBid,2) + ";" +
                 DoubleToString(emaPressureAsk,2) + ";" +
                 DoubleToString(emaPressureRatio,5) + ";" +
                 DoubleToString(emaWeightedMicroDist,2) + ";" +
                 DoubleToString(emaDepthConc2,4) + ";" +
                 DoubleToString(emaDepthConc3,4) + ";" +
                 DoubleToString(emaDepthConc5,4) + ";" +
                 DoubleToString(emaBookEntropy,5) + ";" +
                 DoubleToString(emaBookSymmetry,5) + ";" +
                 DoubleToString(emaBookConvexity,5);

   if(InpSaveRawLevels)
     {
      for(int i=0; i<5; i++)
        {
         line += ";" + DoubleToString(bidPrices[i],2) + ";" + DoubleToString(bidVol[i],0) +
                 ";" + DoubleToString(askPrices[i],2) + ";" + DoubleToString(askVol[i],0);
        }
     }

   ArrayResize(csvLines, lineCount+1);
   csvLines[lineCount] = line;
   lineCount++;

   //--- Atualiza anteriores depois de usar os deltas
   prevBidVol1 = bidVol[0];
   prevAskVol1 = askVol[0];
   prevTotalDepth = totalDepth;
   prevRatio = ratio;
   prevImbalance = imbalance;
   prevSpread = spread;
   prevMicroDist = microDist;
   prevSlopeBid = slopeBid;
   prevSlopeAsk = slopeAsk;
   prevWeightedImbalance = weightedImbalance;
   prevPressureRatio = pressureRatio;
   prevWeightedMicroDist = weightedMicroDist;
   prevDepthConc2 = depthConc2;
   prevBookEntropy = bookEntropy;
   prevValid = true;

   if((int)TimeCurrent() - lastFlushTime >= InpFlushIntervalSec)
     {
      FlushToCSV();
      lastFlushTime = (int)TimeCurrent();
     }
  }

//+------------------------------------------------------------------+
//| Flush para CSV                                                   |
//+------------------------------------------------------------------+
void FlushToCSV()
  {
   if(lineCount == 0) return;

   if(fileHandle == INVALID_HANDLE)
     {
      fileHandle = FileOpen(fileNameFull, FILE_WRITE|FILE_CSV|FILE_ANSI, ";");
      if(fileHandle == INVALID_HANDLE)
        {
         Print("Erro ao abrir arquivo: ", fileNameFull, " erro=", GetLastError());
         return;
        }

      string header = "Timestamp;LastPrice;Bid;Ask;" +
                      "Ratio;Imbalance;TotalDepth;SlopeBid;SlopeAsk;Spread;TopRatio;ImbalN1;ImbalDeep;DepthDelta;MicroPriceDist;AggBuy;AggSell;" +
                      "WeightedImbalance;PressureBid;PressureAsk;PressureRatio;WeightedMicroPrice;WeightedMicroDist;DepthConc2;DepthConc3;DepthConc5;BookEntropy;BookSymmetry;BookConvexity;" +
                      "dRatio;dImbalance;dTotalDepth;dSpread;dMicroDist;dSlopeBid;dSlopeAsk;dWeightedImbalance;dPressureRatio;dWeightedMicroDist;dDepthConc2;dBookEntropy;" +
                      "EMA_Ratio;EMA_Imbalance;EMA_TotalDepth;EMA_SlopeBid;EMA_SlopeAsk;EMA_Spread;EMA_TopRatio;EMA_ImbalN1;EMA_ImbalDeep;EMA_DepthDelta;EMA_MicroDist;EMA_AggBuy;EMA_AggSell;" +
                      "EMA_WeightedImbalance;EMA_PressureBid;EMA_PressureAsk;EMA_PressureRatio;EMA_WeightedMicroDist;EMA_DepthConc2;EMA_DepthConc3;EMA_DepthConc5;EMA_BookEntropy;EMA_BookSymmetry;EMA_BookConvexity";

      if(InpSaveRawLevels)
        {
         for(int i=1; i<=5; i++)
           {
            header += ";BidPrice" + IntegerToString(i) + ";BidVol" + IntegerToString(i) +
                      ";AskPrice" + IntegerToString(i) + ";AskVol" + IntegerToString(i);
           }
        }

      FileWriteString(fileHandle, header + "\r\n");
     }

   for(int i=0; i<lineCount; i++)
      FileWriteString(fileHandle, csvLines[i] + "\r\n");

   FileFlush(fileHandle);
   ArrayResize(csvLines, 0);
   lineCount = 0;
  }
//+------------------------------------------------------------------+
